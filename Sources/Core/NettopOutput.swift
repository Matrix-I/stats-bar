// NettopOutput.swift — turning `nettop -L` CSV into per-process byte counters. Pure: a string in,
// samples out.
//
// This file exists because of where the risk in this feature sits. macOS ships no public API for
// per-process network bytes — rusage_info_v6 counts disk I/O and nothing else, proc_info's sbi_cc is
// socket-buffer occupancy rather than bytes transferred, and NetworkStatistics.framework is private.
// The two alternatives to nettop are worse: the com.apple.network.statistics kernel control means
// private struct layouts that have moved between releases, where a mismatch is misread memory rather
// than a failed parse; and NEFilterDataProvider needs an entitlement this app cannot carry, being
// self-signed and un-notarized. So the numbers come from a command's stdout, and the only defence
// available is to make the parsing itself something a test can hold still.
//
// Two decisions follow from that, and both are about failing in the right direction:
//
//   • Columns are found BY NAME from the header row, never by position. `-J bytes_in,bytes_out` asks
//     for exactly two, but a future nettop that adds one, or reorders them, would otherwise shift a
//     number into the wrong field and be believed. A header without both names returns nil — the
//     whole read is unavailable — instead of a table of plausible wrong figures.
//   • A row that does not parse is skipped; a header that does not parse fails the read. One
//     unfamiliar row should not blank the table, but an unfamiliar shape means we no longer know what
//     any of it means.

import Foundation

/// One process's cumulative network counters, as nettop reported them.
///
/// Cumulative since the process started, not since we last looked — 13.9 GB is an ordinary reading
/// for a VPN daemon that has been up for a week. Turning these into a rate is ProcessNetworkRates'
/// job, and it is the reason a first sample can never produce one.
struct ProcessNetworkSample: Equatable {
    var pid: Int
    /// nettop's accounting name, truncated by the tool to roughly fifteen characters ("Google Chrome H").
    /// Used only as the fallback when the pid owns no NSRunningApplication — see ProcessList.identity.
    var command: String
    var bytesIn: UInt64
    var bytesOut: UInt64
}

enum NettopOutput {
    /// The two columns this parser needs. Named here rather than inline so the argument passed to
    /// `-J` and the names looked up in the header cannot drift apart.
    static let bytesInColumn = "bytes_in"
    static let bytesOutColumn = "bytes_out"

    /// Parses `nettop -P -L 1 -x -n -J bytes_in,bytes_out` output.
    ///
    /// Returns nil when the header does not carry both column names — nettop absent, a usage error
    /// printed instead of data, or an output format this build does not understand. Callers show that
    /// as "unavailable"; it must never be confused with the empty array, which legitimately means the
    /// machine had no network activity to report.
    static func parse(_ text: String) -> [ProcessNetworkSample]? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return nil }

        // The header's first field is empty — the process column is unlabelled — so the name indices
        // line up directly with the data rows' fields, which start with "name.pid" at 0.
        let header = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard let inIndex = header.firstIndex(where: { $0 == bytesInColumn }),
              let outIndex = header.firstIndex(where: { $0 == bytesOutColumn }) else { return nil }

        // Summed rather than overwritten on a repeated pid. `-P` asks for one row per process and
        // that is what it gives today, so this branch is not currently reached; it is here because
        // the alternative when it is reached — silently keeping whichever row happened to come last —
        // would under-report the exact processes the table exists to surface.
        var totals: [Int: ProcessNetworkSample] = [:]
        var order: [Int] = []
        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > max(inIndex, outIndex),
                  let key = fields.first.map(String.init),
                  let (command, pid) = splitProcessKey(key),
                  let bytesIn = UInt64(fields[inIndex]),
                  let bytesOut = UInt64(fields[outIndex]) else { continue }
            if var existing = totals[pid] {
                existing.bytesIn += bytesIn
                existing.bytesOut += bytesOut
                totals[pid] = existing
            } else {
                totals[pid] = ProcessNetworkSample(pid: pid, command: command,
                                                   bytesIn: bytesIn, bytesOut: bytesOut)
                order.append(pid)
            }
        }
        return order.compactMap { totals[$0] }
    }

    /// "Google Chrome H.16714" → ("Google Chrome H", 16714).
    ///
    /// Split at the LAST dot, not the first: reverse-DNS process names are ordinary on this platform
    /// ("com.apple.WebKit.Networking.4821"), and splitting at the first dot would read "com" as the
    /// name and fail to find a pid in the rest. The suffix must parse as a positive Int, which is what
    /// rejects a row whose first field is something else entirely.
    ///
    /// pid 0 is excluded along with the negatives. It is the kernel, it owns no NSRunningApplication,
    /// and `ps`-based tables in this app already skip it.
    static func splitProcessKey(_ key: String) -> (command: String, pid: Int)? {
        guard let dot = key.lastIndex(of: "."), dot != key.startIndex else { return nil }
        let pidText = key[key.index(after: dot)...]
        guard !pidText.isEmpty, pidText.allSatisfy(\.isNumber), let pid = Int(pidText), pid > 0 else { return nil }
        return (String(key[key.startIndex..<dot]), pid)
    }
}
