// PendingFirstReadsTests.swift — pins the bound on how long a battery source may hold a row on the
// pending ellipsis.
//
// Every case here needs a SEQUENCE of events and a clock to reproduce, which is exactly why the
// behaviour was wrong in the first place: the broken version and the fixed one render an identical
// popover for the first few seconds and differ only in what happens after. Nothing in a screenshot,
// and nothing in a single frame, tells them apart.

import Testing
import Foundation
@testable import StatsBarCore

@Suite("Pending first reads")
struct PendingFirstReadsTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func pending(deadline: TimeInterval = 5) -> PendingFirstReads<String> {
        PendingFirstReads<String>(deadline: deadline)
    }

    // MARK: the ordinary path — unchanged by the deadline

    @Test("nothing outstanding is settled")
    func emptyIsSettled() {
        // A Mac with no BLE accessory at all. The source has had its say by saying nothing, and rows
        // must not wait on it.
        #expect(pending().isSettled(now: t0))
    }

    @Test("a read in flight holds the source unsettled")
    func inFlightIsNotSettled() {
        var p = pending()
        p.begin("mouse", at: t0)
        #expect(!p.isSettled(now: t0))
        #expect(!p.isSettled(now: t0.addingTimeInterval(4.9)))
    }

    @Test("finishing the last read settles the source and asks for a republish")
    func finishingTheLastReadRepublishes() {
        // The republish is the load-bearing half: a row sitting on the ellipsis has nothing else to
        // tell it the wait is over, so a finish that returned false here would leave the row pending
        // until some unrelated event happened to publish.
        var p = pending()
        p.begin("mouse", at: t0)
        #expect(p.finish("mouse") == true)
        #expect(p.isSettled(now: t0))
    }

    @Test("finishing one of two does not settle the source")
    func finishingOneOfTwoKeepsWaiting() {
        var p = pending()
        p.begin("mouse", at: t0)
        p.begin("keyboard", at: t0)
        #expect(p.finish("mouse") == false)
        #expect(!p.isSettled(now: t0))
    }

    @Test("finishing something nobody was waiting on republishes nothing")
    func finishingAnUnknownIdIsInert() {
        // The late-callback case. Once a read has expired, CoreBluetooth may still deliver its
        // didFailToConnect minutes later; that must not fire a republish, and must not report the
        // source as having just settled when it settled long ago.
        var p = pending()
        #expect(p.finish("ghost") == false)
        p.begin("mouse", at: t0)
        #expect(p.finish("ghost") == false)
        #expect(!p.isSettled(now: t0))
    }

    // MARK: the deadline — the bug this type exists for

    @Test("a read that overruns stops holding the rows")
    func overrunStopsBlockingTheRows() {
        // The whole defect in one case: CBCentralManager.connect never times out, so without this the
        // answer at any later time is still false — for the life of the process, and for every OTHER
        // device's row as well as this one.
        var p = pending(deadline: 5)
        p.begin("unreachable", at: t0)
        #expect(!p.isSettled(now: t0.addingTimeInterval(4.999)))
        #expect(p.isSettled(now: t0.addingTimeInterval(5)))
        #expect(p.isSettled(now: t0.addingTimeInterval(3600)))
    }

    @Test("the deadline is inclusive at exactly one deadline's worth")
    func deadlineBoundaryIsInclusive() {
        // A read that has taken exactly the deadline has taken the whole of the time it was given.
        // Unobservable against a wall clock and asserted anyway, so the choice stays deliberate rather
        // than whichever comparison the code happened to be written with.
        var p = pending(deadline: 5)
        p.begin("x", at: t0)
        #expect(p.expire(now: t0.addingTimeInterval(4.999)) == false)
        #expect(p.expire(now: t0.addingTimeInterval(5)) == true)
    }

    @Test("expiring the last overdue read asks for a republish exactly once")
    func expiryRepublishesOnce() {
        // Once, not on every poll: refresh() runs at the reader's cadence, so an expire that kept
        // returning true would republish the whole Bluetooth panel every five seconds forever.
        var p = pending(deadline: 5)
        p.begin("x", at: t0)
        #expect(p.expire(now: t0.addingTimeInterval(6)) == true)
        #expect(p.expire(now: t0.addingTimeInterval(7)) == false)
        #expect(p.expire(now: t0.addingTimeInterval(600)) == false)
    }

    @Test("expiring one of two overdue reads still waits for the other")
    func expiryIsPerRead() {
        // Each read carries its own clock. A slow one must not drag a fresh one out with it, which is
        // the per-device reasoning DevicePresenceCache had to be taught separately.
        var p = pending(deadline: 5)
        p.begin("early", at: t0)
        p.begin("late", at: t0.addingTimeInterval(4))
        #expect(p.expire(now: t0.addingTimeInterval(6)) == false)   // "late" is only 2 s old
        #expect(!p.isSettled(now: t0.addingTimeInterval(6)))
        #expect(p.expire(now: t0.addingTimeInterval(9)) == true)
    }

    @Test("isSettled answers on schedule even if expire was never called")
    func settledDoesNotDependOnBeingSwept() {
        // expire() is what produces the republish; isSettled is what keeps the two from disagreeing in
        // between. A caller that polls every five seconds would otherwise keep reporting "still
        // waiting" for up to a whole poll after the deadline had passed.
        var p = pending(deadline: 5)
        p.begin("x", at: t0)
        #expect(p.isSettled(now: t0.addingTimeInterval(6)))
        #expect(p.startedAt.count == 1)   // never swept, and still answering correctly
    }

    @Test("re-beginning an outstanding read does not push its deadline out")
    func rebeginKeepsTheOriginalStart() {
        // The deadline that can never be reached. refresh() runs on a timer and re-offers the same
        // peripherals every tick, so a begin() that reset the clock would extend the window by one
        // interval each time — which is the defect DeviceReadCadence.graceGone was extracted to end,
        // arrived at from the other direction.
        var p = pending(deadline: 5)
        p.begin("x", at: t0)
        p.begin("x", at: t0.addingTimeInterval(4))
        p.begin("x", at: t0.addingTimeInterval(4.5))
        #expect(p.startedAt["x"] == t0)
        #expect(p.isSettled(now: t0.addingTimeInterval(5)))
    }

    @Test("removeAll drops everything without asking for a republish")
    func removeAllClearsState() {
        // The adapter leaving .poweredOn. Every peripheral is invalidated at once with no per-device
        // callback, and `settled` is true for those states anyway, so the caller republishes on the
        // state transition rather than on this.
        var p = pending()
        p.begin("a", at: t0)
        p.begin("b", at: t0)
        p.removeAll()
        #expect(p.startedAt.isEmpty)
        #expect(p.isSettled(now: t0))
    }
}
