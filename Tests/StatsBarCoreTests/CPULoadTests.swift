// CPULoadTests.swift — the tick-delta arithmetic behind the usage ring, the CORES grid and the menu-bar
// percentage.
//
// Three of these cases guard against failures that are invisible on screen: a wrapped UInt32 counter
// (which without wrapping subtraction traps and kills the app, at an interval that depends on how long
// the machine has been up), a core that reported no elapsed ticks (a divide by zero), and the idle
// default of 100 (without which the menu bar reads 100 % for the first tick after launch).

import Testing
@testable import StatsBarCore

@Suite("CPU load")
struct CPULoadTests {

    /// Ticks accumulate, so a delta is all that matters — starting every counter from zero makes the
    /// `current` array literally the deltas under test.
    static func fromZero(_ deltas: [CoreTicks]) -> (previous: [CoreTicks], current: [CoreTicks]) {
        (Array(repeating: CoreTicks(), count: deltas.count), deltas)
    }

    static func derive(_ deltas: [CoreTicks], efficiencyCores: Int = 0,
                       performanceCores: Int = 0) -> CPULoad? {
        let s = fromZero(deltas)
        return CPULoad.between(previous: s.previous, current: s.current,
                               efficiencyCores: efficiencyCores, performanceCores: performanceCores)
    }

    // MARK: The three invisible failures

    @Test("a wrapped counter yields the true delta instead of trapping")
    func handlesCounterWraparound() {
        // The counters are cumulative UInt32. Crossing 2^32 is not hypothetical on a long-running Mac,
        // and `current - previous` would trap there — a crash with no bad input to point at. Wrapping
        // subtraction gives the right answer: 5 &- 4_294_967_291 == 10.
        let previous = [CoreTicks(user: 4_294_967_291, system: 0, idle: 0, nice: 0)]
        let current = [CoreTicks(user: 5, system: 0, idle: 90, nice: 0)]
        let load = CPULoad.between(previous: previous, current: current,
                                   efficiencyCores: 0, performanceCores: 0)
        #expect(load?.userPercent == 10)
        #expect(load?.idlePercent == 90)
        #expect(load?.perCoreBusy == [10])
    }

    @Test("a core with no elapsed ticks reads 0 %, not NaN")
    func handlesZeroElapsedTicks() {
        // Two samples taken close enough together that a parked core advanced nothing. total == 0, so the
        // per-core division has to be guarded — an unguarded 0/0 puts NaN into the bar's width.
        let identical = [CoreTicks(user: 100, system: 50, idle: 900, nice: 0)]
        let load = CPULoad.between(previous: identical, current: identical,
                                   efficiencyCores: 0, performanceCores: 0)
        #expect(load?.perCoreBusy == [0])
        #expect(load?.usagePercent == 0)
        // No delta at all means no reading, so idle stays at its default rather than reporting 0 % idle.
        #expect(load?.idlePercent == 100)
    }

    @Test("idle defaults to 100 so a fresh reader reports 0 % usage, not 100 %")
    func idleDefaultsToFullyIdle() {
        // usagePercent is 100 − idle. This default is what the reader is left holding before its first
        // delta and whenever `between` declines, so getting it wrong pegs the menu-bar glyph at launch.
        #expect(CPULoad().idlePercent == 100)
        #expect(CPULoad().usagePercent == 0)
        #expect(CPULoad().perCoreBusy.isEmpty)
        #expect(CPULoad().efficiencyPercent == nil)
        #expect(CPULoad().performancePercent == nil)
    }

    // MARK: The System / User / Idle split

    @Test("nice time folds into user so the three shares still sum to 100")
    func niceFoldsIntoUser() {
        // Drop nice and user reads 10 % while the three no longer add up — a discrepancy small enough to
        // look like rounding and large enough to be wrong under a niced build job.
        let load = Self.derive([CoreTicks(user: 10, system: 0, idle: 70, nice: 20)])
        #expect(load?.userPercent == 30)
        #expect(load?.systemPercent == 0)
        #expect(load?.idlePercent == 70)
        #expect(load?.perCoreBusy == [30])
    }

    @Test("shares are computed over all cores together")
    func aggregatesAcrossCores() {
        let deltas = Array(repeating: CoreTicks(user: 20, system: 10, idle: 65, nice: 5), count: 4)
        let load = Self.derive(deltas)
        #expect(load?.userPercent == 25)     // (20 + 5) of 100 ticks per core
        #expect(load?.systemPercent == 10)
        #expect(load?.idlePercent == 65)
        #expect(load.map { $0.userPercent + $0.systemPercent + $0.idlePercent } == 100)
        #expect(load?.usagePercent == 35)
        #expect(load?.perCoreBusy == Array(repeating: 35, count: 4))
    }

    // MARK: Per-core detail

    @Test("one pegged core is distinguishable from a lightly loaded machine")
    func perCoreShapeIsPreserved() {
        // The reason the CORES grid exists: a single-threaded job pegging one core and eight cores at
        // 12.5 % produce the SAME overall percentage. Only perCoreBusy separates them.
        var deltas = Array(repeating: CoreTicks(user: 0, system: 0, idle: 100, nice: 0), count: 8)
        deltas[3] = CoreTicks(user: 100, system: 0, idle: 0, nice: 0)
        let load = Self.derive(deltas)
        #expect(load?.perCoreBusy == [0, 0, 0, 100, 0, 0, 0, 0])
        #expect(load?.usagePercent == 12.5)
    }

    // MARK: Cluster averages

    @Test("efficiency cores are the low indices and performance cores follow")
    func clusterSlicingUsesLowIndicesForEfficiency() {
        // Getting this backwards would swap the two DETAILS rows — and read plausibly, since both are
        // percentages. Here the two efficiency cores are pegged and the six performance cores are idle.
        var deltas = Array(repeating: CoreTicks(user: 0, system: 0, idle: 100, nice: 0), count: 8)
        deltas[0] = CoreTicks(user: 100, system: 0, idle: 0, nice: 0)
        deltas[1] = CoreTicks(user: 100, system: 0, idle: 0, nice: 0)
        let load = Self.derive(deltas, efficiencyCores: 2, performanceCores: 6)
        #expect(load?.efficiencyPercent == 100)
        #expect(load?.performancePercent == 0)
    }

    @Test("each cluster average is over that cluster's cores only")
    func clusterAveragesDivideByClusterSize() {
        // Three of the six performance cores busy must read 50 %, not 3/8 of the machine.
        var deltas = Array(repeating: CoreTicks(user: 0, system: 0, idle: 100, nice: 0), count: 8)
        for i in 2...4 { deltas[i] = CoreTicks(user: 100, system: 0, idle: 0, nice: 0) }
        let load = Self.derive(deltas, efficiencyCores: 2, performanceCores: 6)
        #expect(load?.efficiencyPercent == 0)
        #expect(load?.performancePercent == 50)
    }

    @Test("cluster counts that overrun the enumerated cores yield nil, not a trap")
    func clusterGuardsAgainstOverrun() {
        // sysctl's cluster counts and the cores host_processor_info enumerates are two separate reads.
        // Slicing perCoreBusy[2..<8] of a 4-element array would crash rather than mislead.
        let deltas = Array(repeating: CoreTicks(user: 50, system: 0, idle: 50, nice: 0), count: 4)
        let load = Self.derive(deltas, efficiencyCores: 2, performanceCores: 6)
        #expect(load?.efficiencyPercent == 50)   // this cluster still fits
        #expect(load?.performancePercent == nil) // 2 + 6 > 4, so it is declined
    }

    @Test("a chip reporting no clusters gets no cluster rows")
    func noClustersOnIntel() {
        // An Intel Mac reports a single performance level, so both sysctl counts come back 0 and the two
        // DETAILS rows must be absent rather than showing 0 %.
        let load = Self.derive(Array(repeating: CoreTicks(user: 50, system: 0, idle: 50, nice: 0), count: 4))
        #expect(load?.efficiencyPercent == nil)
        #expect(load?.performancePercent == nil)
        #expect(load?.perCoreBusy.count == 4)
    }

    // MARK: Incomparable samples

    @Test("samples with different core counts produce no reading")
    func mismatchedCoreCountsReturnNil() {
        // The reader clears its baseline when polling resumes after a stop; until the next tick the two
        // arrays can disagree. nil leaves the previous defaults in place instead of pairing core 7's
        // counters against core 7 of a different enumeration.
        let previous = Array(repeating: CoreTicks(), count: 8)
        let current = Array(repeating: CoreTicks(user: 10, system: 0, idle: 90, nice: 0), count: 10)
        #expect(CPULoad.between(previous: previous, current: current,
                                efficiencyCores: 2, performanceCores: 6) == nil)
    }

    @Test("an empty enumeration is handled without a reading")
    func emptySamplesAreSafe() {
        let load = CPULoad.between(previous: [], current: [], efficiencyCores: 0, performanceCores: 0)
        #expect(load?.perCoreBusy.isEmpty == true)
        #expect(load?.usagePercent == 0)
    }
}
