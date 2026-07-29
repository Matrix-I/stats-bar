// CPULoad.swift — the load arithmetic: two per-core tick snapshots in, the System / User / Idle split,
// every core's busy share and the two cluster averages out.
//
// Split out of CPUReader.refresh because it is the one stretch of that function with no I/O in it, and
// because it is easy to get subtly wrong in ways the panel would never reveal: the kernel's counters are
// UInt32 and DO wrap, `nice` has to fold into user or the three percentages stop summing to 100, a core
// that reported no elapsed ticks must read 0 % rather than divide by zero, and the idle figure has to
// start at 100 rather than 0 or the menu bar shows a pegged CPU for the first tick after launch.

import Foundation

/// One core's cumulative tick counters, as host_processor_info(PROCESSOR_CPU_LOAD_INFO) reports them.
/// Named fields rather than a `[UInt32]` indexed by CPU_STATE_*, so Mach's index constants stay in the
/// reader and a test can say which counter it is advancing.
struct CoreTicks: Equatable {
    var user: UInt32 = 0
    var system: UInt32 = 0
    var idle: UInt32 = 0
    /// Scheduler-niced user time. Folded INTO user for display, matching Activity Monitor.
    var nice: UInt32 = 0
}

struct CPULoad: Equatable {
    // Shares of total CPU ticks in the sampling window (0…100). `userPercent` folds in nice, so
    // system + user + idle ≈ 100.
    var systemPercent: Double = 0
    var userPercent: Double = 0
    /// 100, not 0, before any delta exists. `usagePercent` is 100 − idle, so a zero default would make a
    /// freshly launched app report a pegged CPU for the tick before its first delta — and this default is
    /// what the reader falls back to whenever `between` declines to produce a reading.
    var idlePercent: Double = 100

    /// Average busy % of each core cluster. nil until the first delta, and on a machine that reports no
    /// such cluster (an Intel Mac with a single performance level).
    var efficiencyPercent: Double? = nil
    var performancePercent: Double? = nil

    /// Busy % of every logical core, in host_processor_info order — efficiency cores at the low indices,
    /// performance cores after them (CPUReader's header records how that was verified). Empty until the
    /// first delta. The cluster averages above are reduced from this, so it costs no extra sampling.
    var perCoreBusy: [Double] = []

    /// The figure shown in the usage ring and the menu bar: everything that isn't idle.
    var usagePercent: Double { max(0, min(100, 100 - idlePercent)) }

    /// The load between two tick snapshots, or nil when they can't be compared — which leaves the caller
    /// holding the defaults above rather than a half-computed reading. A core count that changed between
    /// samples is the real case: the reader clears its baseline whenever polling resumes after a stop.
    static func between(previous: [CoreTicks], current: [CoreTicks],
                        efficiencyCores: Int, performanceCores: Int) -> CPULoad? {
        guard previous.count == current.count else { return nil }

        var sumUser = 0.0, sumSystem = 0.0, sumIdle = 0.0, sumTotal = 0.0
        var perCore = [Double](repeating: 0, count: current.count)

        for c in current.indices {
            // &- deliberately: these are cumulative UInt32 counters and they wrap. Wrapping subtraction
            // still yields the correct delta across a wrap, where a plain `-` would trap and take the
            // whole app down at an interval that depends on how long the machine has been up.
            let du = Double(current[c].user &- previous[c].user)
            let ds = Double(current[c].system &- previous[c].system)
            let dn = Double(current[c].nice &- previous[c].nice)
            let di = Double(current[c].idle &- previous[c].idle)
            let total = du + ds + dn + di

            sumUser += du + dn   // fold nice into user
            sumSystem += ds
            sumIdle += di
            sumTotal += total
            perCore[c] = total > 0 ? (du + ds + dn) / total * 100 : 0
        }

        var out = CPULoad()
        out.perCoreBusy = perCore
        if sumTotal > 0 {
            out.userPercent = sumUser / sumTotal * 100
            out.systemPercent = sumSystem / sumTotal * 100
            out.idlePercent = sumIdle / sumTotal * 100
        }

        // Efficiency cores occupy [0, efficiencyCores); performance cores follow. Both guards are
        // against a chip whose sysctl cluster counts don't add up to the cores actually enumerated —
        // slicing past the end would trap rather than merely mislead.
        if efficiencyCores > 0, efficiencyCores <= current.count {
            out.efficiencyPercent = perCore[0..<efficiencyCores].reduce(0, +) / Double(efficiencyCores)
        }
        if performanceCores > 0, efficiencyCores + performanceCores <= current.count {
            out.performancePercent = perCore[efficiencyCores..<(efficiencyCores + performanceCores)]
                .reduce(0, +) / Double(performanceCores)
        }
        return out
    }
}
