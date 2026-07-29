// MemoryBuckets.swift — the physical-RAM arithmetic: kernel page counts in, the App / Wired /
// Compressed / Cached / Free buckets Activity Monitor shows out, plus the fractions the segmented bar
// and the two rings draw.
//
// Split out of MemoryInfo, which also carries the TOP PROCESSES list and with it AppKit (NSImage) and
// so cannot be reached from a test. That split is worth the forwarding it costs, because BOTH
// fix(memory) commits in this repo's history landed in the few lines below: 62cf4f1 for letting
// reclaimable file pages fall into Free, which over-reported free RAM by 3.2 GB, and 827d7e7 for
// sizing pages with the process page size instead of the kernel's. Neither looks wrong on screen —
// they print plausible gigabytes — so nothing but a test catches them.

import Foundation

/// The page counts from host_statistics64(HOST_VM_INFO64), named.
///
/// Taken as a struct of its own rather than vm_statistics64 so this stays free of Mach — and so a test
/// reads as the situation it describes instead of as a wall of C field names. Counts are UInt32
/// (natural_t) exactly as the kernel reports them.
struct VMPageCounts: Equatable {
    /// Pages wired down — kernel and pinned memory.
    var wired: UInt32 = 0
    /// Pages held by the VM compressor.
    var compressed: UInt32 = 0
    /// Resident anonymous pages. App Memory before purgeable is taken out.
    var internalPages: UInt32 = 0
    /// Resident pages the kernel may drop on demand. A SUBSET of internalPages, which is why it is
    /// subtracted from App Memory and added to Cached Files rather than counted once.
    var purgeable: UInt32 = 0
    /// Resident file-backed pages.
    var external: UInt32 = 0
}

struct MemoryBuckets: Equatable {
    var total: UInt64 = 0        // bytes — physical RAM (hw.memsize)
    var app: UInt64 = 0          // bytes — "App Memory": resident anonymous, non-purgeable
    var wired: UInt64 = 0        // bytes — wired down (kernel / pinned)
    var compressed: UInt64 = 0   // bytes — held by the VM compressor
    var cached: UInt64 = 0       // bytes — "Cached Files": file-backed + purgeable, reclaimable
    var swapUsed: UInt64 = 0     // bytes — swap in use

    /// Page counts → bytes, with `pageSize` the KERNEL page size (host_page_size), not the process
    /// one: host_statistics64 counts kernel pages, and the two disagree in a translated process —
    /// 4 KiB reported against 16 KiB counted — which under-reports every bucket by 4×.
    static func fromPages(total: UInt64, pages: VMPageCounts,
                          pageSize: UInt64, swapUsed: UInt64 = 0) -> MemoryBuckets {
        func bytes(_ p: UInt32) -> UInt64 { UInt64(p) * pageSize }

        var out = MemoryBuckets()
        out.total = total
        out.wired = bytes(pages.wired)
        out.compressed = bytes(pages.compressed)
        // purgeable is a subset of internalPages, but guard the subtraction: the read isn't one atomic
        // snapshot, so a transient race can leave purgeable the larger of the two. Unsigned `-` TRAPS
        // in Swift, and build_app.sh ships -O rather than -Ounchecked, so unguarded this is a crash
        // during a routine refresh — not the 68 TB App Memory figure a wrapping subtraction would give.
        out.app = bytes(pages.internalPages >= pages.purgeable
                        ? pages.internalPages - pages.purgeable : 0)
        // "Cached Files" — resident file-backed pages, plus the purgeable pages just excluded from App
        // Memory. Both hold data the kernel can drop on demand, but they are NOT free: without this
        // bucket the Free remainder swallows them and the panel over-reports free RAM by gigabytes.
        // Kept out of `used` so the menu-bar percentage is unaffected.
        out.cached = bytes(pages.external) + bytes(pages.purgeable)
        out.swapUsed = swapUsed
        return out
    }

    /// Memory Used = App + Wired + Compressed (Activity Monitor's definition). Plain `+`: these are
    /// three fractions of physical RAM, so the sum can't come near UInt64's ceiling — and were that
    /// assumption ever to break, trapping beats a silent wrap.
    var used: UInt64 { app + wired + compressed }

    /// Everything left once the three "used" buckets and the file cache are accounted for: truly-free
    /// plus speculative pages. Guarded because `used + cached` can edge past `total` — a wired
    /// anonymous page is counted in both `wired` and `app`, and the read isn't a single atomic
    /// snapshot. Cached files used to land here, which is why Free read several GB too high.
    var free: UInt64 { total > used + cached ? total - used - cached : 0 }

    // Fractions of total physical RAM (0…1) for the segmented bar. Free is drawn as the remainder.
    var appFraction: Double        { fraction(app) }
    var wiredFraction: Double      { fraction(wired) }
    var compressedFraction: Double { fraction(compressed) }
    var cachedFraction: Double     { fraction(cached) }

    // Used share of physical RAM (0…1) and the same figure as a percentage, for the usage ring.
    var usedFraction: Double { fraction(used) }
    var usagePercent: Double { usedFraction * 100 }

    /// A continuous 0…1 proxy for the pressure ring's arc: the share of RAM that can't simply be
    /// reclaimed on demand (wired + compressed). It grows as real pressure builds, so the arc tracks
    /// the state — but the colour and word come from MemoryInfo.pressure, the authoritative kernel level.
    var pressureFraction: Double { fraction(wired + compressed) }

    private func fraction(_ v: UInt64) -> Double {
        total > 0 ? Double(v) / Double(total) : 0
    }
}
