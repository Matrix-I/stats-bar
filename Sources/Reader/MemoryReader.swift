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

    private var timer: Timer?
    private var interval: TimeInterval = 0

    private static let idleInterval: TimeInterval = 2   // menu-bar % only
    private static let activeInterval: TimeInterval = 1 // live readout while the panel is open

    init() {
        refresh()
        schedule(Self.idleInterval)
    }

    private func schedule(_ seconds: TimeInterval) {
        guard seconds != interval else { return }
        interval = seconds
        timer?.invalidate()
        // .common modes so the timer keeps firing while the popover's run loop is in event-tracking.
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Poll once a second while the panel is visible; drop back to the lazy menu-bar-only cadence
    /// when it closes.
    func setPanelOpen(_ open: Bool) {
        schedule(open ? Self.activeInterval : Self.idleInterval)
        if open { refresh() }
    }

    func refresh() {
        guard var out = MemoryStats.read() else { return }
        out.pressure = Self.pressureLevel()
        info = out
    }

    /// The macOS memory-pressure level. The sysctl returns the dispatch-source constants
    /// (1 = normal, 2 = warning, 4 = critical); a read failure or any unexpected value is treated as
    /// normal so the ring never falsely alarms.
    private static func pressureLevel() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        switch level {
        case 4:  return .critical
        case 2:  return .warning
        default: return .normal
        }
    }
}
