// MemoryInfo.swift — live physical-RAM + swap snapshot, mirroring the categories macOS Activity
// Monitor shows (App / Wired / Compressed, with Free as the remainder). Populated from
// host_statistics64(HOST_VM_INFO64) + sysctl vm.swapusage — see MemoryStats.

import Foundation

struct MemoryInfo {
    var total: UInt64 = 0        // bytes — physical RAM (hw.memsize)
    var app: UInt64 = 0          // bytes — "App Memory": resident anonymous, non-purgeable
    var wired: UInt64 = 0        // bytes — wired down (kernel / pinned)
    var compressed: UInt64 = 0   // bytes — held by the VM compressor
    var swapUsed: UInt64 = 0     // bytes — swap in use

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

    private func fraction(_ v: UInt64) -> Double {
        total > 0 ? Double(v) / Double(total) : 0
    }
}
