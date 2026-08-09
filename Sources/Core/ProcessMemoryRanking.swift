// ProcessMemoryRanking.swift — which processes belong in the RAM popover's TOP PROCESSES table, and
// in what order. Pure: pids and byte counts in, a ranked list out.
//
// This exists because the table used to be whatever `ps -A -m` handed back, truncated to six. That is
// a ranking by RESIDENT SET SIZE, printed under a column header reading "Memory" — Activity Monitor's
// own name for a different quantity. Activity Monitor shows phys_footprint, which counts a process's
// compressed and IOKit-mapped pages even though they are not resident, and excludes shared pages that
// are. The two disagree in both directions, so the error is not a readable offset that a user could
// learn to correct for: measured across one machine's table, individual rows ran from 0.87x to 1.63x,
// and a separate audit saw 4.17x.
//
// The ordering is the part that matters, and it is why this is a ranking type rather than a unit fix.
// Sorting by the wrong quantity does not merely mis-order the rows — it changes WHICH rows exist. On
// the machine this was written on, the top six by RSS and the top six by footprint overlapped in three
// of six: two processes holding 373 MB and 333 MB were absent from the table entirely, displaced by
// rows that were themselves overstated by half. So the actual offender could be invisible while the
// list looked authoritative.
//
// That would be a reporting bug on its own. What makes it worth a pure type with tests is that every
// row in that table carries a "Quit <name>" context menu, and the view's own comment says quitting is
// usually what you came to the list to do. A wrong ranking therefore steers a destructive action at
// the wrong process.

import Foundation

/// One process as the reader sampled it, before it is ranked or given a display name.
struct ProcessMemorySample: Equatable {
    var pid: Int
    /// The `ps` accounting name, used only if the pid owns no NSRunningApplication.
    var command: String
    /// Resident set size in bytes, from `ps -o rss`.
    var residentBytes: UInt64
    /// phys_footprint in bytes, or nil when the process could not be inspected.
    ///
    /// nil is common and not an error: proc_pid_rusage returns EPERM for processes belonging to
    /// another user, which on a normal desktop is roughly 40% of the table — all root daemons. Those
    /// keep their resident size rather than being dropped, because a daemon that really is holding a
    /// gigabyte should still be visible; an approximate row beats a missing one here, and the two
    /// figures agree closely for processes that neither compress nor map much.
    var footprintBytes: UInt64?

    /// What this process is ranked and displayed by.
    var effectiveBytes: UInt64 { footprintBytes ?? residentBytes }

    init(pid: Int, command: String, residentBytes: UInt64, footprintBytes: UInt64? = nil) {
        self.pid = pid
        self.command = command
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
    }
}

enum ProcessMemoryRanking {

    /// The `count` heaviest processes, heaviest first.
    ///
    /// Ties break on the lower pid so the table cannot reorder itself between two reads that found
    /// the same numbers — a row swapping places under the cursor is how a right-click ends up on the
    /// wrong process. `count` is clamped, so a caller asking for none or for a negative number gets an
    /// empty table rather than a crash on a negative prefix.
    static func top(_ count: Int, from samples: [ProcessMemorySample]) -> [ProcessMemorySample] {
        guard count > 0 else { return [] }
        let ranked = samples.sorted {
            $0.effectiveBytes == $1.effectiveBytes ? $0.pid < $1.pid
                                                   : $0.effectiveBytes > $1.effectiveBytes
        }
        return Array(ranked.prefix(count))
    }
}
