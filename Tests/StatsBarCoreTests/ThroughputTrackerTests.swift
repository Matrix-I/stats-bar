// ThroughputTrackerTests.swift — the session totals and the live rate.
//
// This is the most branch-heavy piece of arithmetic in the app, and every branch is there because of a
// real event: an interface bounce restarting the counters at zero, a Wi-Fi→Ethernet switch, a sample
// arriving too soon to divide by, a disconnection, the first sample of a session. Each one gets a test
// below, driven by an explicit clock — which is the only reason a rate can be asserted at all.

import Testing
@testable import StatsBarCore

@Suite("Throughput tracker")
struct ThroughputTrackerTests {

    /// DispatchTime.uptimeNanoseconds is nanoseconds, so a second is 1e9. Named because a wrong power of
    /// ten here is exactly the sort of mistake these tests exist to catch.
    static let second: UInt64 = 1_000_000_000

    static func sample(_ interface: String = "en0", rx: UInt64, tx: UInt64) -> ThroughputTracker.Sample {
        .init(interface: interface, rxBytes: rx, txBytes: tx)
    }

    // MARK: The ordinary case

    @Test("rate is the byte delta divided by the elapsed interval")
    func rateOverOneSecond() {
        var t = ThroughputTracker()
        t.prime(with: Self.sample(rx: 1_000, tx: 500), atNanoseconds: 0)
        let r = t.update(with: Self.sample(rx: 1_000 + 2_000_000, tx: 500 + 300_000),
                         atNanoseconds: Self.second)
        #expect(r.downloadRate == 2_000_000)   // 2 MB in one second
        #expect(r.uploadRate == 300_000)
        #expect(r.downloadTotal == 2_000_000)  // session total counts from the baseline
        #expect(r.uploadTotal == 300_000)
    }

    @Test("a half-second interval doubles the per-second figure")
    func rateScalesWithInterval() {
        // The division is by seconds, not by ticks: the same bytes over half the time is twice the rate.
        var t = ThroughputTracker()
        t.prime(with: Self.sample(rx: 0, tx: 0), atNanoseconds: 0)
        let r = t.update(with: Self.sample(rx: 500_000, tx: 0), atNanoseconds: Self.second / 2)
        #expect(r.downloadRate == 1_000_000)
    }

    @Test("totals accumulate across ticks while the rate reflects only the last interval")
    func totalsAccumulateAndRateDoesNot() {
        var t = ThroughputTracker()
        t.prime(with: Self.sample(rx: 0, tx: 0), atNanoseconds: 0)
        t.update(with: Self.sample(rx: 1_000_000, tx: 0), atNanoseconds: Self.second)
        let r = t.update(with: Self.sample(rx: 1_500_000, tx: 0), atNanoseconds: 2 * Self.second)
        #expect(r.downloadTotal == 1_500_000)   // since the baseline
        #expect(r.downloadRate == 500_000)      // only the second interval
    }

    // MARK: Samples too close together

    @Test("an interval below the floor holds the previous rate instead of dividing by it")
    func tooSoonHoldsTheLastRate() {
        // A 20 ms gap with one frame in it would read as tens of KB/s. Holding the last real figure is
        // what keeps the menu-bar rate from flickering when a tick lands early.
        var t = ThroughputTracker()
        t.prime(with: Self.sample(rx: 0, tx: 0), atNanoseconds: 0)
        t.update(with: Self.sample(rx: 1_000_000, tx: 0), atNanoseconds: Self.second)
        let r = t.update(with: Self.sample(rx: 1_001_500, tx: 0),
                         atNanoseconds: Self.second + 20_000_000)   // +20 ms
        #expect(r.downloadRate == 1_000_000)    // unchanged from the previous interval
        #expect(r.downloadTotal == 1_001_500)   // the total still takes the bytes
    }

    @Test("the interval floor is 0.2 s exclusive")
    func intervalFloorBoundary() {
        // Pinned because it is the one magic number in here: exactly 0.2 s must NOT measure, just past it
        // must. `dt > minimumInterval`, not >=.
        var atFloor = ThroughputTracker()
        atFloor.prime(with: Self.sample(rx: 0, tx: 0), atNanoseconds: 0)
        #expect(atFloor.update(with: Self.sample(rx: 1_000, tx: 0),
                               atNanoseconds: 200_000_000).downloadRate == 0)

        var pastFloor = ThroughputTracker()
        pastFloor.prime(with: Self.sample(rx: 0, tx: 0), atNanoseconds: 0)
        #expect(pastFloor.update(with: Self.sample(rx: 1_000, tx: 0),
                                 atNanoseconds: 200_000_001).downloadRate > 0)
    }

    // MARK: Counter resets and interface switches

    @Test("an interface bounce that restarts the counters does not underflow the total")
    func counterResetRebaselines() {
        // The counters restart at 0 when an interface bounces. Without the rebaseline, `rxBytes -
        // baselineRx` underflows — and unsigned `-` traps in Swift, so that is a crash, not a total
        // reading 16 exabytes.
        var t = ThroughputTracker()
        t.prime(with: Self.sample(rx: 5_000_000, tx: 1_000_000), atNanoseconds: 0)
        let r = t.update(with: Self.sample(rx: 1_000, tx: 200), atNanoseconds: Self.second)
        #expect(r.downloadTotal == 0)   // rebaselined to the new, lower counter
        #expect(r.uploadTotal == 0)
        #expect(r.downloadRate == 0)    // and no rate measured on the restarting tick
    }

    @Test("a counter that restarts in one direction only still rebaselines")
    func asymmetricCounterResetRebaselines() {
        // The case above drops rx AND tx together, so either half of the `||` satisfies it on its own —
        // it passes with one clause missing. Real resets are not symmetric: a driver reload can restart
        // the rx counter while tx keeps climbing, and a send-heavy link primed at rx 0 never satisfies
        // the rx clause at all. Getting this wrong is not a wrong number: the total is computed with a
        // plain UInt64 subtraction, which traps, so a missed rebaseline crashes the app mid-refresh.
        var rxDips = ThroughputTracker()
        rxDips.prime(with: Self.sample(rx: 5_000_000, tx: 1_000_000), atNanoseconds: 0)
        let afterRxDip = rxDips.update(with: Self.sample(rx: 1_000, tx: 2_000_000),
                                       atNanoseconds: Self.second)
        #expect(afterRxDip.downloadTotal == 0)
        #expect(afterRxDip.uploadTotal == 0)   // the whole session restarts, not just the dipping half
        #expect(afterRxDip.downloadRate == 0)

        var txDips = ThroughputTracker()
        txDips.prime(with: Self.sample(rx: 5_000_000, tx: 1_000_000), atNanoseconds: 0)
        let afterTxDip = txDips.update(with: Self.sample(rx: 9_000_000, tx: 200),
                                       atNanoseconds: Self.second)
        #expect(afterTxDip.downloadTotal == 0)
        #expect(afterTxDip.uploadTotal == 0)
        #expect(afterTxDip.downloadRate == 0)
    }

    @Test("switching interface restarts the session rather than diffing across the two")
    func interfaceSwitchRebaselines() {
        // en0's counters and en7's are unrelated numbers. Ethernet reading lower than Wi-Fi would
        // underflow; reading higher would credit the session with traffic that never happened.
        var t = ThroughputTracker()
        t.prime(with: Self.sample("en0", rx: 1_000_000, tx: 500_000), atNanoseconds: 0)
        let r = t.update(with: Self.sample("en7", rx: 9_000_000, tx: 8_000_000),
                         atNanoseconds: Self.second)
        #expect(r.downloadTotal == 0)
        #expect(r.uploadTotal == 0)
        #expect(r.downloadRate == 0)
    }

    @Test("after a rebaseline the next interval measures normally")
    func rebaselineDoesNotWedgeTheRate() {
        // The rebaseline sets the sample time to now, so the tick after it has a proper interval again.
        // Getting that wrong would leave the rate stuck at 0 for the rest of the session.
        var t = ThroughputTracker()
        t.prime(with: Self.sample("en0", rx: 1_000_000, tx: 0), atNanoseconds: 0)
        t.update(with: Self.sample("en7", rx: 0, tx: 0), atNanoseconds: Self.second)
        let r = t.update(with: Self.sample("en7", rx: 400_000, tx: 0), atNanoseconds: 2 * Self.second)
        #expect(r.downloadRate == 400_000)
        #expect(r.downloadTotal == 400_000)
    }

    @Test("a counter that dips without the interface changing reports no traffic rather than trapping")
    func rateGuardsAgainstBackwardCounters() {
        // Distinct from the rebaseline path: here the counter is still above the baseline, so the
        // rebaseline never fires and the rate's own >= guard is the only thing left — and what it is
        // guarding against is a trap, since the delta it feeds is a plain UInt64 subtraction.
        var t = ThroughputTracker()
        t.prime(with: Self.sample(rx: 1_000, tx: 1_000), atNanoseconds: 0)
        t.update(with: Self.sample(rx: 5_000, tx: 5_000), atNanoseconds: Self.second)
        let r = t.update(with: Self.sample(rx: 3_000, tx: 3_000), atNanoseconds: 2 * Self.second)
        #expect(r.downloadRate == 0)
        #expect(r.uploadRate == 0)
        #expect(r.downloadTotal == 2_000)   // still measured from the baseline of 1_000
    }

    // MARK: Disconnection

    @Test("losing the interface zeroes the rate but keeps the session totals")
    func disconnectionZeroesRateKeepsTotals() {
        var t = ThroughputTracker()
        t.prime(with: Self.sample(rx: 0, tx: 0), atNanoseconds: 0)
        t.update(with: Self.sample(rx: 1_000_000, tx: 400_000), atNanoseconds: Self.second)
        let r = t.update(with: nil, atNanoseconds: 2 * Self.second)
        #expect(r.downloadRate == 0)          // the glyph must stop drawing a frozen value
        #expect(r.uploadRate == 0)
        #expect(r.downloadTotal == 1_000_000) // cumulative for the session — deliberately survives
        #expect(r.uploadTotal == 400_000)
    }

    @Test("reconnecting re-primes instead of dividing the whole offline gap")
    func reconnectionDoesNotCountTheOfflineGap() {
        // The bug this prevents: an hour offline, then one sample. Dividing the accumulated bytes by the
        // gap — or worse, dividing them by one second — invents a rate that never happened.
        var t = ThroughputTracker()
        t.prime(with: Self.sample(rx: 0, tx: 0), atNanoseconds: 0)
        t.update(with: Self.sample(rx: 1_000_000, tx: 0), atNanoseconds: Self.second)
        t.update(with: nil, atNanoseconds: 2 * Self.second)

        let hourLater = 3_600 * Self.second
        let first = t.update(with: Self.sample(rx: 9_000_000, tx: 0), atNanoseconds: hourLater)
        #expect(first.downloadRate == 0)             // the returning sample only re-primes
        #expect(first.downloadTotal == 9_000_000)    // totals are still counted from the baseline

        let next = t.update(with: Self.sample(rx: 9_500_000, tx: 0),
                            atNanoseconds: hourLater + Self.second)
        #expect(next.downloadRate == 500_000)        // and the interval after it measures normally
    }

    // MARK: Before anything has been read

    @Test("a fresh tracker reports zeroes")
    func freshTrackerIsZero() {
        #expect(ThroughputTracker().reading == ThroughputTracker.Reading())
    }

    @Test("the first sample of a session yields totals but no rate")
    func firstSampleHasNoRate() {
        // Nothing to measure against yet. Note the tracker was never primed here — this is the path taken
        // when the machine had no primary interface at launch.
        var t = ThroughputTracker()
        let r = t.update(with: Self.sample(rx: 4_000, tx: 2_000), atNanoseconds: 5 * Self.second)
        #expect(r.downloadRate == 0)
        #expect(r.uploadRate == 0)
        // The first sample becomes the baseline, so the session starts from zero rather than crediting
        // every byte since boot to this session.
        #expect(r.downloadTotal == 0)
        #expect(r.uploadTotal == 0)
    }

    @Test("a clock that does not advance produces no reading rather than trapping")
    func nonAdvancingClockIsSafe() {
        // now == last means dividing by zero; now < last means an underflowing UInt64 subtraction. Neither
        // can happen with a monotonic clock, which is why this is a guard and not a feature.
        var t = ThroughputTracker()
        t.prime(with: Self.sample(rx: 0, tx: 0), atNanoseconds: 10 * Self.second)
        #expect(t.update(with: Self.sample(rx: 1_000, tx: 0),
                         atNanoseconds: 10 * Self.second).downloadRate == 0)
        #expect(t.update(with: Self.sample(rx: 2_000, tx: 0),
                         atNanoseconds: 9 * Self.second).downloadRate == 0)
    }
}
