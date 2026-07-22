// MemoryReader.swift — the ObservableObject behind the Memory menu-bar item. It publishes a live
// MemoryInfo built from the Mach VM statistics (App / Wired / Compressed / Free + swap — see
// MemoryStats) plus the macOS memory-pressure level (kern.memorystatus_vm_pressure_level). Both are
// a couple of cheap syscalls, so the read runs on the main thread at ~1 Hz.
//
// Like the other readers, it polls a touch faster while the popover is open (so the rings move
// smoothly) and drops back to a lazy cadence when closed — the menu-bar percentage stays live
// either way.

import Foundation
import Combine

final class MemoryReader: ObservableObject {
    @Published var info = MemoryInfo()

    private lazy var poll = PollingTimer { [weak self] in self?.refresh() }
    private var panelOpen = false

    private static let idleInterval: TimeInterval = 2   // menu-bar % only
    private static let activeInterval: TimeInterval = 1 // live readout while the panel is open

    // Top-processes list: read via `ps` on a background queue (it blocks briefly), at most every two
    // seconds, only while the panel is open. Cached so the 1 Hz path can republish it without
    // re-running ps. cachedTop is touched on the main thread only. Mirrors CPUReader.
    private var cachedTop: [MemoryProcess] = []
    private lazy var topRead = ThrottledBackgroundValue<[MemoryProcess]>(label: "MemoryReader.top", every: 2)
    private static let topCount = 6

    init() {
        refresh()
        poll.schedule(every: Self.idleInterval)
    }

    /// Poll once a second while the panel is visible; drop back to the lazy menu-bar-only cadence
    /// when it closes.
    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        poll.schedule(every: open ? Self.activeInterval : Self.idleInterval)
        if open { refresh() }
    }

    func refresh() {
        guard var out = MemoryStats.read() else { return }
        out.pressure = Self.pressureLevel()

        // Top memory consumers — popover-only (a ps spawn); publish the last list we have.
        if panelOpen { maybeReadTopProcesses() }
        out.topProcesses = cachedTop

        info = out
    }

    /// Refresh the top-processes list at most every two seconds, off the main thread (ps blocks
    /// briefly). Mirrors CPUReader's cached, gated read.
    private func maybeReadTopProcesses() {
        topRead.request(produce: { Self.readTopProcesses(Self.topCount) }) { [weak self] procs in
            guard let self else { return }
            self.cachedTop = procs
            // Republish right away so the list appears promptly on first open, not one tick later.
            var cur = self.info
            cur.topProcesses = procs
            self.info = cur
        }
    }

    /// The `count` heaviest processes by resident memory: `ps -o rss` (KiB) sorted with `-m`
    /// (descending by memory). Like CPUReader's list, GUI apps get their NSRunningApplication name +
    /// icon via ProcessList. pid 0 is skipped.
    private static func readTopProcesses(_ count: Int) -> [MemoryProcess] {
        guard let data = DeviceTool.run("/bin/ps", ["-A", "-c", "-o", "pid=,rss=,comm=", "-m"]),
              let out = String(data: data, encoding: .utf8) else { return [] }
        var result: [MemoryProcess] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int(parts[0]), let rssKB = UInt64(parts[1]), pid != 0 else { continue }
            let comm = parts[2...].joined(separator: " ")
            let (name, icon) = ProcessList.identity(pid: pid, fallback: comm)
            result.append(MemoryProcess(pid: pid, name: name, bytes: rssKB * 1024, icon: icon))
            if result.count >= count { break }
        }
        return result
    }

    /// The macOS memory-pressure level. The sysctl returns the dispatch-source constants
    /// (1 = normal, 2 = warning, 4 = critical); a read failure or any unexpected value is treated as
    /// normal so the ring never falsely alarms.
    private static func pressureLevel() -> MemoryPressure {
        switch Sysctl.int("kern.memorystatus_vm_pressure_level") {
        case 4:  return .critical
        case 2:  return .warning
        default: return .normal
        }
    }
}
