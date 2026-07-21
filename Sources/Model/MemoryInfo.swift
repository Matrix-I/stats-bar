// MemoryInfo.swift — live physical-RAM + swap snapshot, mirroring the categories macOS Activity
// Monitor shows (App / Wired / Compressed, with Free as the remainder). Populated from
// host_statistics64(HOST_VM_INFO64) + sysctl vm.swapusage — see MemoryStats. The memory-pressure
// level comes from kern.memorystatus_vm_pressure_level, set by MemoryReader.

import Foundation

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
    var total: UInt64 = 0        // bytes — physical RAM (hw.memsize)
    var app: UInt64 = 0          // bytes — "App Memory": resident anonymous, non-purgeable
    var wired: UInt64 = 0        // bytes — wired down (kernel / pinned)
    var compressed: UInt64 = 0   // bytes — held by the VM compressor
    var swapUsed: UInt64 = 0     // bytes — swap in use
    var pressure: MemoryPressure = .normal   // authoritative macOS pressure level (set by the reader)

    // Memory Used = App + Wired + Compressed (Activity Monitor's definition). Plain `+`: these are
    // three fractions of physical RAM, so the sum can't come near UInt64's ceiling — and were that
    // assumption ever to break, trapping beats a silent wrap.
    var used: UInt64 { app + wired + compressed }

    // Everything not in the three "used" buckets: truly-free + speculative + cached files. Guarded
    // because `used` can edge slightly past `total` — a wired anonymous page is counted in both
    // `wired` and `app`, and the read isn't a single atomic snapshot.
    var free: UInt64 { total > used ? total - used : 0 }

    // Fractions of total physical RAM (0…1) for the segmented bar. Free is drawn as the remainder.
    var appFraction: Double        { fraction(app) }
    var wiredFraction: Double      { fraction(wired) }
    var compressedFraction: Double { fraction(compressed) }

    // Used share of physical RAM (0…1) and the same figure as a percentage, for the usage ring.
    var usedFraction: Double { fraction(used) }
    var usagePercent: Double { usedFraction * 100 }

    // A continuous 0…1 proxy for the pressure ring's arc: the share of RAM that can't simply be
    // reclaimed on demand (wired + compressed). It grows as real pressure builds, so the arc tracks
    // the state — but the colour and word come from `pressure`, the authoritative kernel level.
    var pressureFraction: Double { fraction(wired + compressed) }

    private func fraction(_ v: UInt64) -> Double {
        total > 0 ? Double(v) / Double(total) : 0
    }
}
