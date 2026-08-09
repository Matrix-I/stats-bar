// DeviceReadCadenceTests.swift — how often the phone readers look, and whether the ride-out window they
// hand DevicePresenceCache can actually fire.
//
// The last case here is the one worth having. Every other case asserts a number or an inequality, which a
// careful reader could have checked by eye. `theRideOutCanActuallyFireOnTheSlowPath` instead drives the
// sequence the shipped code got wrong for four releases — poll every 5 s, hand the cache a 3 s window,
// lose the device on the first enumeration blip — and shows that the window was dead code that read like
// a safety net. Nothing about that is visible in a single frame, or in the constant.
//
// What is NOT here, and cannot be: whether the reader's Timer actually runs at these intervals. That is
// live-object behaviour, so it was checked by compiling the real IOSDeviceReader into a throwaway harness
// and timing its publishes across a popover open and close. Worth recording, because that harness is what
// caught the first attempt at this file — a `shouldRead` predicate sampled by a faster timer, which beat
// against it and turned a 2 s interval into 3 s. Every test in this file passed while it did that.

import Testing
import Foundation
@testable import StatsBarCore

@Suite("Device read cadence")
struct DeviceReadCadenceTests {

    /// The cadence the app actually ships. IOSDeviceReader constructs `DeviceReadCadence()` with no
    /// arguments, so asserting against the defaults here pins the shipped numbers rather than a copy of
    /// them — the mistake CLAUDE.md's "541 of 8,139" anecdote is about.
    static let c = DeviceReadCadence()

    /// The Android reader's, which differs in one interval and is likewise named on the type rather than
    /// assembled at its call site, so this asserts against what that reader ships too.
    static let android = DeviceReadCadence.android

    /// All four states, so a case that must hold for every audience can say so instead of picking one.
    static let states: [(watcher: DeviceReadCadence.Watcher, attached: Bool, name: String)] = [
        (.popover, true,  "popover open"),
        (.glyph,   true,  "glyph only"),
        (.nobody,  true,  "nobody looking, phone attached"),
        (.nobody,  false, "nobody looking, nothing attached"),
    ]

    // MARK: The intervals

    @Test("each audience gets its own interval")
    func intervalPerAudience() {
        #expect(Self.c.interval(.popover, deviceAttached: true) == 1)
        #expect(Self.c.interval(.glyph, deviceAttached: true) == 2)
        #expect(Self.c.interval(.nobody, deviceAttached: true) == 5)
        #expect(Self.c.interval(.nobody, deviceAttached: false) == 10)
    }

    @Test("only the unwatched interval depends on whether a phone is attached")
    func attachedOnlyMattersWhenUnwatched() {
        // Guards against wiring `deviceAttached` into the watched branches, where it would silently slow
        // the popover down to the keep-warm rate whenever the enumeration briefly came back empty.
        #expect(Self.c.interval(.popover, deviceAttached: true) == Self.c.interval(.popover, deviceAttached: false))
        #expect(Self.c.interval(.glyph, deviceAttached: true) == Self.c.interval(.glyph, deviceAttached: false))
        #expect(Self.c.interval(.nobody, deviceAttached: true) != Self.c.interval(.nobody, deviceAttached: false))
    }

    @Test("watching more closely never reads less often")
    func closerWatchingReadsMoreOften() {
        #expect(Self.c.interval(.popover, deviceAttached: true) <= Self.c.interval(.glyph, deviceAttached: true))
        #expect(Self.c.interval(.glyph, deviceAttached: true) <= Self.c.interval(.nobody, deviceAttached: true))
        #expect(Self.c.interval(.nobody, deviceAttached: true) <= Self.c.interval(.nobody, deviceAttached: false))
    }

    @Test("every interval is a whole number of seconds")
    func intervalsAreWholeSeconds() {
        // Not cosmetic. The reader points its Timer straight at these, and a fractional interval would put
        // reads on a drifting phase against the second boundaries every other cadence here lands on —
        // which is the drift that made the gated design read a 2 s interval every 3 s.
        for s in Self.states {
            let i = Self.c.interval(s.watcher, deviceAttached: s.attached)
            #expect(i == i.rounded(), "\(s.name) is \(i)s")
            #expect(i > 0, "\(s.name) would stop the timer")
        }
    }

    // MARK: The ride-out window

    @Test("the ride-out window is never shorter than the interval in force")
    func rideOutCoversAtLeastOneInterval() {
        // The defect this type exists for. A window shorter than the polling interval can never fire:
        // the previous sighting is already older than it by the time the next tick enumerates. Setting
        // blipMargin to 0, or going back to a constant, turns this red for the 5 s and 10 s states.
        for s in Self.states {
            let i = Self.c.interval(s.watcher, deviceAttached: s.attached)
            let g = Self.c.graceGone(s.watcher, deviceAttached: s.attached)
            #expect(g > i, "\(s.name): ride-out \(g)s cannot survive a \(i)s polling gap")
        }
    }

    @Test("opening the popover tightens the ride-out as well as the interval")
    func lookingTightensTheRideOut() {
        // Otherwise an unplug would linger on screen for the off-screen window while the user watches it.
        #expect(Self.c.graceGone(.popover, deviceAttached: true)
                < Self.c.graceGone(.nobody, deviceAttached: true))
        #expect(Self.c.graceGone(.nobody, deviceAttached: true)
                < Self.c.graceGone(.nobody, deviceAttached: false))
    }

    // MARK: The Android reader's cadence

    @Test("the Android ride-out is never shorter than its own interval either")
    func androidRideOutCoversAtLeastOneInterval() {
        // The same invariant as above, asserted separately because the Android reader was NOT holding to
        // it: a flat 5 s window against a 10 s keep-warm cadence, which is a ride-out that cannot fire
        // at all. Deriving both from one type is what makes a divergence like that impossible rather
        // than merely unlikely, and this is the assertion that says so.
        for s in Self.states {
            let i = Self.android.interval(s.watcher, deviceAttached: s.attached)
            let g = Self.android.graceGone(s.watcher, deviceAttached: s.attached)
            #expect(g > i, "\(s.name): ride-out \(g)s cannot survive a \(i)s polling gap")
        }
    }

    @Test("the Android cadence differs from the iOS one only off-screen")
    func androidDiffersOnlyWhereItHasAReason() {
        // A named variant earns its keep only if the difference is the one it was named for. The
        // off-screen interval stays slow because that reader has no TemperatureAlerter, so the faster
        // one would buy nothing and cost an adb round trip every five seconds; everything else must be
        // the shared numbers, not a second set quietly drifting from them.
        for s in Self.states where !(s.watcher == .nobody && s.attached) {
            #expect(Self.android.interval(s.watcher, deviceAttached: s.attached)
                    == Self.c.interval(s.watcher, deviceAttached: s.attached), "\(s.name)")
        }
        #expect(Self.android.interval(.nobody, deviceAttached: true) == 10)
        #expect(Self.c.interval(.nobody, deviceAttached: true) == 5)
        // And with both `.nobody` intervals equal, being attached no longer changes the answer — which
        // is exactly what this reader's own keep-warm timer did before it moved onto this type.
        #expect(Self.android.interval(.nobody, deviceAttached: true)
                == Self.android.interval(.nobody, deviceAttached: false))
    }

    // MARK: The two types together

    /// Minimal stand-in for a phone row; the cache is generic, so nothing here needs Sources/Model.
    private struct Dev: Equatable {
        var id: String
        var capturedAt: Date?
    }

    @Test("the ride-out can actually fire on the slow path")
    func theRideOutCanActuallyFireOnTheSlowPath() {
        // The shipped bug, as a sequence. Nobody is watching and a phone is attached, so reads land every
        // offScreenInterval (5 s). At t=5 the enumeration comes back empty — one adb/usbmux blip, not an
        // unplug. The device must still be on screen, and must disappear only once the window is spent.
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        func at(_ s: Double) -> Date { epoch.addingTimeInterval(s) }

        let interval = Self.c.interval(.nobody, deviceAttached: true)
        let derived = Self.c.graceGone(.nobody, deviceAttached: true)

        func run(graceGone: TimeInterval) -> [String] {
            var cache = DevicePresenceCache<Dev, String>(graceGone: graceGone)
            var seen: [String] = []
            // t=0: the phone is there and reads fine.
            _ = cache.resolve([Dev(id: "a", capturedAt: at(0))], now: at(0), id: \.id,
                              kind: { _ in .good }, capturedAt: \.capturedAt)
            // t=5 and t=10: two consecutive empty enumerations, one interval apart.
            for tick in [interval, interval * 2] {
                let rows = cache.resolve([], now: at(tick), id: \.id,
                                         kind: { _ in .good }, capturedAt: \.capturedAt)
                seen.append(rows.isEmpty ? "gone" : "held")
            }
            return seen
        }

        // What the code shipped: a 3 s window against a 5 s polling gap. The blip is indistinguishable
        // from an unplug, so the row vanishes on the very first empty tick.
        #expect(run(graceGone: 3) == ["gone", "gone"])

        // What the derived window does: survive the blip, then let the device go on the next one — which
        // is the behaviour the 3 s constant was written to produce and never did.
        #expect(derived > interval)
        #expect(run(graceGone: derived) == ["held", "gone"])
    }

    @Test("the Android reader's ride-out could not fire either, for twice the margin")
    func theAndroidRideOutCouldNotFire() {
        // The same shipped bug, in the file that did not get fixed when the iOS one did — and worse:
        // 5 s against a 10 s keep-warm cadence, so the previous sighting was already twice the age of
        // the window by the time the next tick enumerated. The comment beside that 5 s justified it as
        // "a little longer than the iOS reader's 3 s", which is a comparison with a constant that had
        // already been deleted, against an interval it never mentioned.
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        func at(_ s: Double) -> Date { epoch.addingTimeInterval(s) }

        let interval = Self.android.interval(.nobody, deviceAttached: true)
        let derived = Self.android.graceGone(.nobody, deviceAttached: true)
        #expect(interval == 10)

        func firstBlip(graceGone: TimeInterval) -> String {
            var cache = DevicePresenceCache<Dev, String>(graceGone: graceGone)
            _ = cache.resolve([Dev(id: "a", capturedAt: at(0))], now: at(0), id: \.id,
                              kind: { _ in .good }, capturedAt: \.capturedAt)
            let rows = cache.resolve([], now: at(interval), id: \.id,
                                     kind: { _ in .good }, capturedAt: \.capturedAt)
            return rows.isEmpty ? "gone" : "held"
        }

        #expect(firstBlip(graceGone: 5) == "gone")          // what shipped
        #expect(firstBlip(graceGone: derived) == "held")    // what the derived window does
    }
}
