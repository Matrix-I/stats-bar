// MemoryBuckets.swift — the physical-RAM arithmetic: kernel page counts in, the App / Wired /
// Compressed / Cached / Free buckets Activity Monitor shows out, plus the fractions the segmented bar
// and the two rings draw.
//
// Split out of MemoryInfo, which also carries the TOP PROCESSES list and with it AppKit (NSImage) and
// so cannot be reached from a test. That split is worth the forwarding it costs, because ALL THREE
// fix(memory) commits in this repo's history landed in the few lines below: 62cf4f1 for letting
// reclaimable file pages fall into Free, which over-reported free RAM by 3.2 GB, 827d7e7 for sizing
// pages with the process page size instead of the kernel's, and this rewrite. None of them looks wrong
// on screen — they print plausible gigabytes — so nothing but a test catches them.
//
// The third had the same shape as the first, which is the reason for the change below rather than
// another patch. FREE WAS A REMAINDER — whatever was left of the nameplate after the other buckets —
// and a remainder silently absorbs anything the buckets do not name. The first time, that was the file
// cache, 3.2 GB of it. This time it was macOS's own firmware carveout, 0.6 GB, and the fix is not to
// subtract one more term but to stop deriving Free at all: the kernel reports free pages, so Free is
// measured like every other bucket and what the buckets do not cover is named `reserved` instead of
// being quietly called free. A remainder cannot be wrong about only one thing.
//
// The second consequence of that shape was the denominator. Every fraction divided by the nameplate,
// which includes memory the VM cannot hand out, so the usage ring read 81% where the truth was 84%,
// the colour ramp fired a band late, and the menu-bar percentage could not exceed 96%. Fractions now
// divide by `total`, the RAM actually under management.

import Foundation

/// The page counts from host_statistics64(HOST_VM_INFO64), named.
///
/// Taken as a struct of its own rather than vm_statistics64 so this stays free of Mach — and so a test
/// reads as the situation it describes instead of as a wall of C field names. Counts are UInt32
/// (natural_t) exactly as the kernel reports them.
struct VMPageCounts: Equatable {
    /// `vm_statistics64.free_count` VERBATIM — which is not the free page count. The kernel reports it
    /// as `vm_page_free_count + speculative_count` (osfmk/kern/host.c), and those speculative pages are
    /// also inside `external`, so taking this at face value counts them in both Free and Cached Files.
    /// `vm_stat` prints the subtraction already done, which is why its "Pages free" line and this field
    /// disagree by hundreds of megabytes.
    ///
    /// No default, deliberately: a fixture that omitted it would silently mean "a machine with no free
    /// memory", and the whole point of measuring Free rather than inferring it is that nobody should be
    /// able to leave it unsaid.
    var free: UInt32

    /// File pages read ahead speculatively. A subset of BOTH `free` above and `external` below, hence
    /// subtracted from Free exactly once and left in Cached Files, where it belongs — these pages hold
    /// data, they are simply cheap to drop.
    var speculative: UInt32

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
    /// The nameplate: hw.memsize, the figure on the spec sheet. HEADLINE ONLY — never a denominator.
    ///
    /// It is not the amount of RAM the VM manages, and the gap is not small. macOS reserves a
    /// firmware/kernel carveout that the page counters never account for: 644,595,712 bytes on a 16 GiB
    /// M1 Pro, which xnu publishes as the difference between `hw.memsize` (max_mem_actual) and
    /// `hw.memsize_usable` (max_mem), and seeds `vm_page_wire_count` against the smaller of the two
    /// (osfmk/vm/vm_resident.c). Dividing by this number is the mistake that made the usage ring read
    /// 81% where the truth was 84%, put the colour ramp a band late, and capped the menu-bar figure at
    /// 96% — see `total`.
    var installed: UInt64 = 0    // bytes — hw.memsize
    var app: UInt64 = 0          // bytes — "App Memory": resident anonymous, non-purgeable
    var wired: UInt64 = 0        // bytes — wired down (kernel / pinned)
    var compressed: UInt64 = 0   // bytes — held by the VM compressor
    var cached: UInt64 = 0       // bytes — "Cached Files": file-backed + purgeable, reclaimable
    /// bytes — genuinely free pages, MEASURED rather than left over. See the type header.
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0     // bytes — swap in use

    /// Page counts → bytes, with `pageSize` the KERNEL page size (host_page_size), not the process
    /// one: host_statistics64 counts kernel pages, and the two disagree in a translated process —
    /// 4 KiB reported against 16 KiB counted — which under-reports every bucket by 4×.
    static func fromPages(installed: UInt64, pages: VMPageCounts,
                          pageSize: UInt64, swapUsed: UInt64 = 0) -> MemoryBuckets {
        func bytes(_ p: UInt32) -> UInt64 { UInt64(p) * pageSize }

        var out = MemoryBuckets()
        out.installed = installed
        // Free is measured, never a remainder. Guarded because free_count and speculative_count are
        // not read under a lock, so a torn read can briefly leave speculative the larger — and unsigned
        // `-` TRAPS under -O rather than wrapping.
        out.free = bytes(pages.free >= pages.speculative ? pages.free - pages.speculative : 0)
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

    /// The RAM the VM actually manages, and the denominator for every fraction below. Derived from the
    /// buckets rather than read from a sysctl, so it needs no `hw.memsize_usable` — a key that is not
    /// guaranteed on every Mac this ships to — and stays right in a VM and on Intel.
    ///
    /// It differs from `installed` by the carveout described there. Measured on a 16 GiB M1 Pro this
    /// sum lands within about 4 MB of `hw.memsize_usable` across hundreds of samples, the remainder
    /// being pages in flight between queues during a non-atomic read.
    var total: UInt64 { used + cached + free }

    /// Installed RAM that the VM never accounts for. Named rather than banked in Free, because it is
    /// memory that is NOT AVAILABLE, not memory that is idle.
    ///
    /// This is the bug this file was rewritten for. Free used to be `installed − used − cached`, so
    /// every byte of the carveout landed in it: the panel reported 0.66 GB free on a machine that was
    /// 3.11 GB into swap and had 0.05 GB genuinely free, and the row had a hard floor of 0.60 GB that
    /// it could never print below. The relative error grew without bound as memory ran out — measured
    /// between 2.1x and 12.75x — so the figure was least trustworthy exactly when someone looked at it.
    /// Guarded: a torn read can put the buckets a few pages past `installed`.
    var reserved: UInt64 { installed > total ? installed - total : 0 }

    // Fractions of total physical RAM (0…1) for the segmented bar. Free is drawn as the remainder.
    var appFraction: Double        { fraction(app) }
    var wiredFraction: Double      { fraction(wired) }
    var compressedFraction: Double { fraction(compressed) }
    var cachedFraction: Double     { fraction(cached) }
    /// Free is a bucket like the others now, so it has a fraction like the others. The bar still draws
    /// it as the remainder of the track — that is a drawing decision, not an arithmetic one — but the
    /// five fractions summing to 1 is now something a test can check rather than something the shape
    /// of the code guaranteed.
    var freeFraction: Double       { fraction(free) }

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
