// ProcessNetworkRatesTests.swift — the arithmetic that turns lifetime byte counters into a live rate.
//
// Two of these guard a crash rather than a wrong number. nettop reports UInt64 counters, and this repo
// ships -O rather than -Ounchecked, so `a - b` with b > a halts the process — CLAUDE.md's rule, and
// reachable here every time a pid is reused by a process whose counters start at zero. The negative
// case below is the guard; deleting it does not make the table wrong, it makes the app die while the
// popover is open.
//
// The rest exist because the honest failure of a rate is a plausible number. A first sweep that
// divided a lifetime total by one tick would put a browser at several gigabytes a second, and it would
// look exactly like a browser at several gigabytes a second.

import Testing
@testable import StatsBarCore

@Suite("Process network rates")
struct ProcessNetworkRatesTests {

    let second: UInt64 = 1_000_000_000

    func sample(_ pid: Int, _ command: String = "curl",
                       in bytesIn: UInt64, out bytesOut: UInt64) -> ProcessNetworkSample {
        ProcessNetworkSample(pid: pid, command: command, bytesIn: bytesIn, bytesOut: bytesOut)
    }

    // MARK: A rate needs two samples, and the first one is not a rate

    @Test("the first sweep reports nothing, however large the counters are")
    func firstSweepReportsNothing() {
        // The whole point. These counters are cumulative since the process started, so a browser that
        // has moved four gigabytes since login arrives with four gigabytes in its first sample. Treating
        // an absent baseline as a zero baseline would rank it first at a rate no link can carry, and
        // nothing about the resulting row would look wrong.
        var rates = ProcessNetworkRates()
        let out = rates.update(with: [sample(1, "Safari", in: 4_000_000_000, out: 200_000_000)],
                               atNanoseconds: second)
        #expect(out.isEmpty)
        #expect(rates.hasMeasured == false)
    }

    @Test("the second sweep divides the delta by the elapsed time")
    func secondSweepMeasuresTheDelta() {
        var rates = ProcessNetworkRates()
        rates.update(with: [sample(1, in: 1_000, out: 500)], atNanoseconds: second)
        let out = rates.update(with: [sample(1, in: 3_000, out: 1_500)], atNanoseconds: 3 * second)
        #expect(out.count == 1)
        #expect(out.first?.bytesInPerSec == 1_000)    // 2_000 bytes over 2 s
        #expect(out.first?.bytesOutPerSec == 500)
        #expect(out.first?.totalPerSec == 1_500)
        #expect(rates.hasMeasured)
    }

    @Test("a process that appears mid-session is primed, not measured from zero")
    func newProcessIsPrimedFirst() {
        // The same bug as the first sweep, arriving one tick later: a download that starts while the
        // popover is open enters with its whole lifetime total in hand.
        var rates = ProcessNetworkRates()
        rates.update(with: [sample(1, in: 100, out: 100)], atNanoseconds: second)
        let arrival = rates.update(with: [sample(1, in: 200, out: 100),
                                          sample(2, "curl", in: 900_000, out: 0)],
                                   atNanoseconds: 2 * second)
        #expect(arrival.map(\.pid) == [1])            // pid 2 primed only
        let next = rates.update(with: [sample(1, in: 200, out: 100),
                                       sample(2, "curl", in: 901_000, out: 0)],
                                atNanoseconds: 3 * second)
        #expect(next.map(\.pid) == [2])               // now measured: 1_000 B over 1 s
        #expect(next.first?.bytesInPerSec == 1_000)
    }

    // MARK: pid reuse — the case that crashes rather than misreports

    @Test("counters that fall are re-baselined instead of subtracted")
    func fallingCountersDoNotTrap() {
        // A pid is reused after its process exits and the new occupant starts at zero. `before - now`
        // on UInt64 traps at -O. Skipping the round and re-priming is the only correct answer: the two
        // processes' counters are not comparable at all.
        var rates = ProcessNetworkRates()
        rates.update(with: [sample(7, "curl", in: 5_000_000, out: 5_000_000)], atNanoseconds: second)
        let out = rates.update(with: [sample(7, "curl", in: 10, out: 10)], atNanoseconds: 2 * second)
        #expect(out.isEmpty)
        // And the re-baseline took, so the NEXT sweep measures against the new occupant's counters
        // rather than the dead process's.
        let next = rates.update(with: [sample(7, "curl", in: 60, out: 10)], atNanoseconds: 3 * second)
        #expect(next.first?.bytesInPerSec == 50)
    }

    @Test("one counter falling is enough to re-baseline, even if the other rose")
    func eitherCounterFallingIsEnough() {
        // A weaker guard checking only bytesIn would trap on the bytesOut subtraction instead. Both
        // are checked, so this asserts the half a one-sided guard would miss.
        var rates = ProcessNetworkRates()
        rates.update(with: [sample(7, in: 1_000, out: 9_000)], atNanoseconds: second)
        #expect(rates.update(with: [sample(7, in: 2_000, out: 5)], atNanoseconds: 2 * second).isEmpty)
    }

    @Test("a pid whose accounting name changed is a different process")
    func changedCommandIsRebaselined() {
        // Counters can also rise across a pid reuse — the new occupant may simply have moved more
        // than the old one had. The name is the only other thing that says they are not the same
        // process, so it is checked too.
        var rates = ProcessNetworkRates()
        rates.update(with: [sample(7, "curl", in: 100, out: 100)], atNanoseconds: second)
        let out = rates.update(with: [sample(7, "ssh", in: 900, out: 900)], atNanoseconds: 2 * second)
        #expect(out.isEmpty)
    }

    @Test("a process that vanishes and returns is measured from its new counters")
    func vanishedProcessIsForgotten() {
        // Indirect assertion that the baseline is replaced wholesale rather than merged: if the old
        // entry survived the sweep it was absent from, the return would be measured against a stale
        // baseline — and here that would read as 800 B/s rather than nothing.
        var rates = ProcessNetworkRates()
        rates.update(with: [sample(7, in: 100, out: 100)], atNanoseconds: second)
        rates.update(with: [], atNanoseconds: 2 * second)
        let out = rates.update(with: [sample(7, in: 900, out: 100)], atNanoseconds: 3 * second)
        #expect(out.isEmpty)
    }

    // MARK: Intervals

    @Test("two samples too close together hold the previous rates")
    func tooShortAnIntervalHoldsTheLastRates() {
        var rates = ProcessNetworkRates()
        rates.update(with: [sample(1, in: 0, out: 0)], atNanoseconds: second)
        let measured = rates.update(with: [sample(1, in: 1_000, out: 0)], atNanoseconds: 2 * second)
        #expect(measured.first?.bytesInPerSec == 1_000)
        // 100 ms later, under minimumInterval: the quotient would measure scheduling, not traffic.
        let held = rates.update(with: [sample(1, in: 1_050, out: 0)], atNanoseconds: 2 * second + 100_000_000)
        #expect(held == measured)
    }

    @Test("a gap longer than maximumInterval reports nothing rather than an average")
    func tooLongAnIntervalReportsNothing() {
        // The machine slept, or the timer stalled. Dividing an hour of traffic by an hour is
        // arithmetically fine and a lie in a column headed with a live rate.
        var rates = ProcessNetworkRates()
        rates.update(with: [sample(1, in: 0, out: 0)], atNanoseconds: second)
        let out = rates.update(with: [sample(1, in: 3_600_000_000, out: 0)],
                               atNanoseconds: second + 3_600 * second)
        #expect(out.isEmpty)
        // Re-primed, so the sweep after the wake measures normally.
        let next = rates.update(with: [sample(1, in: 3_600_002_000, out: 0)],
                                atNanoseconds: second + 3_602 * second)
        #expect(next.first?.bytesInPerSec == 1_000)
    }

    @Test("the boundaries themselves are measured, not rejected", arguments: [
        ProcessNetworkRates.minimumInterval, ProcessNetworkRates.maximumInterval,
    ])
    func intervalBoundsAreInclusive(interval: Double) {
        // Both guards are >= / <=. A test that only ever passed clearly-inside values would accept a
        // strict inequality here, which is an off-by-one that shows up as an occasional dropped tick.
        var rates = ProcessNetworkRates()
        rates.update(with: [sample(1, in: 0, out: 0)], atNanoseconds: 10 * second)
        let at = 10 * second + UInt64(interval * 1_000_000_000)
        let out = rates.update(with: [sample(1, in: 1_000, out: 0)], atNanoseconds: at)
        #expect(out.count == 1)
        #expect(out.first?.bytesInPerSec == 1_000 / interval)
    }

    // MARK: What makes a row, and in what order

    @Test("a process that moved nothing is not a row")
    func idleProcessIsNotARow() {
        // Otherwise the table is five daemons at 0 B/s and the process actually using the link is
        // wherever the sort happened to put it.
        var rates = ProcessNetworkRates()
        rates.update(with: [sample(1, in: 500, out: 500), sample(2, "idle", in: 10, out: 10)],
                     atNanoseconds: second)
        let out = rates.update(with: [sample(1, in: 900, out: 500), sample(2, "idle", in: 10, out: 10)],
                               atNanoseconds: 2 * second)
        #expect(out.map(\.pid) == [1])
    }

    @Test("rows are ranked by download and upload combined, highest first")
    func rankedByCombinedRate() {
        var rates = ProcessNetworkRates()
        let base = [sample(1, "a", in: 0, out: 0), sample(2, "b", in: 0, out: 0), sample(3, "c", in: 0, out: 0)]
        rates.update(with: base, atNanoseconds: second)
        let out = rates.update(with: [sample(1, "a", in: 100, out: 0),      // 100
                                      sample(2, "b", in: 0, out: 900),      // 900 — upload only, still first
                                      sample(3, "c", in: 300, out: 200)],   // 500
                               atNanoseconds: 2 * second)
        #expect(out.map(\.pid) == [2, 3, 1])
    }

    @Test("equal rates are ordered by pid, so the table does not flicker")
    func tiesBreakOnPid() {
        // Without a total order the sort falls back to input order, which is nettop's, which is not
        // stable between sweeps — two equal rows would swap places every second on screen.
        var rates = ProcessNetworkRates()
        let base = [sample(9, "a", in: 0, out: 0), sample(4, "b", in: 0, out: 0)]
        rates.update(with: base, atNanoseconds: second)
        let out = rates.update(with: [sample(9, "a", in: 100, out: 0), sample(4, "b", in: 100, out: 0)],
                               atNanoseconds: 2 * second)
        #expect(out.map(\.pid) == [4, 9])
    }
}
