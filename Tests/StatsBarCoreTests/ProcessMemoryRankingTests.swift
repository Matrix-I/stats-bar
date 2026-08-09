// ProcessMemoryRankingTests.swift — the RAM popover's TOP PROCESSES table picks the right processes.
//
// The shipped defect was not a wrong number in a row; it was a wrong SET of rows. `ps -m` ranks by
// resident set size and the table was labelled with Activity Monitor's word for phys_footprint, so
// processes that hold most of their memory compressed ranked far below where they belong. Half the
// table could be the wrong processes while every visible figure still looked plausible — and each row
// carries a "Quit" menu, so the list was steering a destructive action.
//
// The numbers below are one real sample from the machine this was found on, pid for pid.

import Testing
@testable import StatsBarCore

@Suite("Process memory ranking")
struct ProcessMemoryRankingTests {

    /// A live `ps` + proc_pid_rusage sample, six rows, taken while the bug was being confirmed. Two
    /// rows understate (a renderer with much of its memory compressed), four overstate.
    static let sample = [
        ProcessMemorySample(pid: 501, command: "Google Chrome Helper (Renderer)",
                            residentBytes: 1_864_270_643, footprintBytes: 2_138_657_587),
        ProcessMemorySample(pid: 502, command: "Claude Helper (Renderer)",
                            residentBytes: 898_629_632, footprintBytes: 1_012_089_651),
        ProcessMemorySample(pid: 503, command: "claude",
                            residentBytes: 476_268_134, footprintBytes: 311_738_368),
        ProcessMemorySample(pid: 504, command: "claude",
                            residentBytes: 444_198_912, footprintBytes: 272_629_760),
        ProcessMemorySample(pid: 505, command: "Claude Helper",
                            residentBytes: 100_020_224, footprintBytes: 391_741_440),
        ProcessMemorySample(pid: 506, command: "Google Chrome Helper",
                            residentBytes: 122_366_361, footprintBytes: 350_099_046),
    ]

    // MARK: The shipped defect

    @Test("a process holding compressed memory is not ranked below one that is merely resident")
    func rankingUsesFootprintNotResident() {
        // The membership error, at its smallest. pid 505 has a third of pid 503's resident size and a
        // quarter more actual memory. Ranked by rss it is last; ranked truthfully it is third. A table
        // of three would have shown pid 503 and hidden pid 505 — the heavier of the two.
        let top3 = ProcessMemoryRanking.top(3, from: Self.sample).map(\.pid)
        #expect(top3 == [501, 502, 505])

        let byResident = Self.sample.sorted { $0.residentBytes > $1.residentBytes }.prefix(3).map(\.pid)
        #expect(byResident == [501, 502, 503])   // what shipped
        #expect(top3 != Array(byResident))
    }

    @Test("half a six-row table can be the wrong processes")
    func theWholeSetCanDiffer() {
        // Not a rhetorical claim: this is the measured overlap on the sample above, which is why the
        // fix is a ranking rather than a relabelling. Ranked by rss the table would end on two rows
        // that do not belong in it at all.
        let truthful = Set(ProcessMemoryRanking.top(4, from: Self.sample).map(\.pid))
        let shipped = Set(Self.sample.sorted { $0.residentBytes > $1.residentBytes }.prefix(4).map(\.pid))
        #expect(truthful == [501, 502, 505, 506])
        #expect(shipped == [501, 502, 503, 504])
        #expect(truthful.intersection(shipped).count == 2)
    }

    @Test("the displayed size is the footprint, not the resident size")
    func rowsCarryTheFootprint() {
        let top = ProcessMemoryRanking.top(1, from: Self.sample)
        #expect(top.first?.effectiveBytes == 2_138_657_587)
        #expect(top.first?.effectiveBytes != top.first?.residentBytes)
    }

    // MARK: Processes we may not inspect

    @Test("a process that cannot be inspected keeps its resident size instead of vanishing")
    func deniedProcessesFallBackToResident() {
        // proc_pid_rusage answers EPERM for another user's processes — about 40% of the table on a
        // normal desktop, all root daemons. Dropping them would hide a daemon that really is holding a
        // gigabyte, so they rank on what we can see.
        let daemon = ProcessMemorySample(pid: 99, command: "kernel_task",
                                         residentBytes: 3_000_000_000, footprintBytes: nil)
        #expect(daemon.effectiveBytes == 3_000_000_000)
        #expect(ProcessMemoryRanking.top(1, from: Self.sample + [daemon]).map(\.pid) == [99])
    }

    // MARK: Determinism and bounds

    @Test("equal sizes break on the pid, so the table cannot reshuffle under the cursor")
    func tiesAreStable() {
        // Every row has a "Quit <name>" context menu. Two rows swapping places between two reads that
        // measured the same bytes is how a right-click lands on the wrong process.
        let tied = [
            ProcessMemorySample(pid: 300, command: "b", residentBytes: 1000),
            ProcessMemorySample(pid: 100, command: "a", residentBytes: 1000),
            ProcessMemorySample(pid: 200, command: "c", residentBytes: 1000),
        ]
        #expect(ProcessMemoryRanking.top(3, from: tied).map(\.pid) == [100, 200, 300])
        #expect(ProcessMemoryRanking.top(3, from: tied.reversed()).map(\.pid) == [100, 200, 300])
    }

    @Test("asking for no rows, or fewer rows than exist, is answered rather than trapped")
    func countIsClamped() {
        // `prefix` tolerates a count past the end, but Array(prefix(-1)) traps — and the caller passes
        // a configured constant, not a literal.
        #expect(ProcessMemoryRanking.top(0, from: Self.sample).isEmpty)
        #expect(ProcessMemoryRanking.top(-5, from: Self.sample).isEmpty)
        #expect(ProcessMemoryRanking.top(99, from: Self.sample).count == Self.sample.count)
        #expect(ProcessMemoryRanking.top(6, from: []).isEmpty)
    }
}
