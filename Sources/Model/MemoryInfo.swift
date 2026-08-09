// MemoryInfo.swift — live physical-RAM + swap snapshot, mirroring the categories macOS Activity
// Monitor shows (App / Wired / Compressed, with Free as the remainder). Populated from
// host_statistics64(HOST_VM_INFO64) + sysctl vm.swapusage — see MemoryStats. The memory-pressure
// level comes from kern.memorystatus_vm_pressure_level, set by MemoryReader.

import Foundation
import AppKit

/// One row of the RAM tab's TOP PROCESSES table: a process's display name, app icon (nil for
/// daemons/helpers that own no NSRunningApplication) and its resident memory in bytes (from `ps rss`,
/// resident set size — a close, no-privilege proxy for Activity Monitor's "Memory" column).
struct MemoryProcess: Identifiable {
    let pid: Int
    let name: String
    let bytes: UInt64
    let icon: NSImage?
    var id: Int { pid }
}

/// macOS memory-pressure level, from `kern.memorystatus_vm_pressure_level` — the same signal that
/// drives Activity Monitor's green / yellow / red pressure graph.
enum MemoryPressure {
    case normal, warning, critical

    var label: String {
        switch self {
        case .normal:   return "Normal"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        }
    }
}

struct MemoryInfo {
    /// The byte figures and every quantity derived from them. Lives in Sources/Core (MemoryBuckets) so
    /// it can be unit-tested — this type can't be, since MemoryProcess pulls in AppKit.
    var buckets = MemoryBuckets()
    var pressure: MemoryPressure = .normal   // authoritative macOS pressure level (set by the reader)

    // The heaviest memory consumers right now (from `ps`, popover-only — see MemoryReader).
    var topProcesses: [MemoryProcess] = []

    // Read-only forwards, so the panels and the menu-bar label keep reading `info.free` rather than
    // `info.buckets.free` at some twenty call sites. Nothing is computed here: every one of these is
    // MemoryBuckets' own property, and that is the only place the arithmetic exists.
    /// The spec-sheet figure, for the headline above the rings and nothing else. Every ratio uses
    /// `total`, which is the RAM the VM actually manages — see MemoryBuckets.
    var installed: UInt64  { buckets.installed }
    var total: UInt64      { buckets.total }
    var reserved: UInt64   { buckets.reserved }
    var app: UInt64        { buckets.app }
    var wired: UInt64      { buckets.wired }
    var compressed: UInt64 { buckets.compressed }
    var cached: UInt64     { buckets.cached }
    var swapUsed: UInt64   { buckets.swapUsed }
    var used: UInt64       { buckets.used }
    var free: UInt64       { buckets.free }

    var appFraction: Double        { buckets.appFraction }
    var wiredFraction: Double      { buckets.wiredFraction }
    var compressedFraction: Double { buckets.compressedFraction }
    var cachedFraction: Double     { buckets.cachedFraction }
    var usedFraction: Double       { buckets.usedFraction }
    var usagePercent: Double       { buckets.usagePercent }
    var pressureFraction: Double   { buckets.pressureFraction }
}
