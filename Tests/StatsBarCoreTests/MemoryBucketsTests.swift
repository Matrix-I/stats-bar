// MemoryBucketsTests.swift — the RAM arithmetic, which is the only part of this repo with THREE
// shipped bugs in its history (62cf4f1, 827d7e7, and the carveout this file was extended for). All
// three printed believable gigabytes while being wrong, so the cases below are written to reproduce
// each one specifically rather than to describe the code.
//
// The first and third were the same mistake twice: Free was a REMAINDER, so it silently absorbed
// whatever the other buckets failed to name — the file cache the first time, macOS's firmware carveout
// the second. That is why the central assertion here is no longer "the buckets sum to the total", which
// was an algebraic identity of the remainder formula and could not fail for any input. It is that Free
// does not depend on the total at all.
//
// Two fixtures. `pages` is a synthetic machine whose page counts tile its installed RAM exactly, so
// every figure is a whole number of 16 KiB pages against a power-of-two total and the literals are
// exact. `m1Pro` is the machine the bug was reported on, page for page from vm_stat.

import Testing
@testable import StatsBarCore

@Suite("Memory buckets")
struct MemoryBucketsTests {

    static let sixteenGiB: UInt64 = 17_179_869_184
    static let kernelPage: UInt64 = 16_384   // Apple Silicon

    /// A plausible mid-session snapshot whose counts account for every page of the installed RAM —
    /// 418,576 + 100,000 + 50,000 + 300,000 + 180,000 = 1,048,576 = 16 GiB / 16 KiB. Chosen that way so
    /// `reserved` is zero here and the carveout cases below have to use a machine where it is not.
    static let pages = VMPageCounts(free: 418_576,
                                    speculative: 0,
                                    wired: 100_000,
                                    compressed: 50_000,
                                    internalPages: 300_000,
                                    purgeable: 20_000,
                                    external: 180_000)

    /// The reported 16 GiB M1 Pro, from its vm_stat. `free` is free_count, so it is the 3,747 pages
    /// vm_stat prints as free PLUS the 3,703 speculative ones the kernel folds into that field.
    static let m1Pro = VMPageCounts(free: 7_450,
                                    speculative: 3_703,
                                    wired: 155_882,
                                    compressed: 388_319,
                                    internalPages: 332_502,
                                    purgeable: 40,
                                    external: 128_499)

    static func snapshot(pageSize: UInt64 = kernelPage, swapUsed: UInt64 = 0) -> MemoryBuckets {
        MemoryBuckets.fromPages(installed: sixteenGiB, pages: pages,
                                pageSize: pageSize, swapUsed: swapUsed)
    }

    static var reported: MemoryBuckets {
        MemoryBuckets.fromPages(installed: sixteenGiB, pages: m1Pro, pageSize: kernelPage)
    }

    // MARK: The three bugs this file exists for

    @Test("reclaimable file pages land in Cached, not in Free — the 3.2 GB over-report")
    func cachedFilesAreNotCountedAsFree() {
        let b = Self.snapshot()
        // What 62cf4f1 did: subtract only `used` from the total, leaving every reclaimable file page
        // sitting in Free. The gap between that and the truth is the whole Cached bucket — 3.28 GB
        // here, the same order as the 3.2 GB measured on the real machine.
        let freeAsTheBugComputedIt = Self.sixteenGiB - b.used
        #expect(b.free == 6_857_949_184)
        #expect(freeAsTheBugComputedIt - b.free == b.cached)
        #expect(b.cached == 3_276_800_000)
    }

    @Test("bucket sizes scale with the page size they are given")
    func pageSizeIsLoadBearing() {
        // 827d7e7: host_statistics64 counts KERNEL pages, but the code sized them with the PROCESS
        // page size. The two agree natively and differ 4× in a translated process, which under-reported
        // every bucket by 4× — visible only as "my Mac says it's using 2 GB".
        let kernel = Self.snapshot(pageSize: 16_384)
        let process = Self.snapshot(pageSize: 4_096)
        #expect(kernel.app == process.app * 4)
        #expect(kernel.wired == process.wired * 4)
        #expect(kernel.compressed == process.compressed * 4)
        #expect(kernel.cached == process.cached * 4)
        #expect(kernel.free == process.free * 4)
    }

    @Test("Free is a property of the page counts, never of the total it is compared against")
    func freeDoesNotDependOnInstalled() {
        // THE DEFECT, in one line. Free used to be `installed − used − cached`, so every byte of
        // hw.memsize that the VM does not account for landed in it. The page counts say the same thing
        // whichever total you hold them against, so Free must too — what changes instead is Reserved.
        // A scaling relation rather than a literal, the analogue of pageSizeIsLoadBearing.
        let onNameplate = MemoryBuckets.fromPages(installed: 17_179_869_184, pages: Self.m1Pro,
                                                  pageSize: Self.kernelPage)
        let onUsable = MemoryBuckets.fromPages(installed: 16_535_273_472, pages: Self.m1Pro,
                                               pageSize: Self.kernelPage)
        #expect(onNameplate.free == onUsable.free)
        #expect(onNameplate.total == onUsable.total)
        #expect(onNameplate.reserved - onUsable.reserved == 644_595_712)
    }

    @Test("the carveout is Reserved, not Free — the panel that read 0.66 GB free while swapping")
    func theCarveoutIsNotBankedInFree() {
        let b = Self.reported
        #expect(b.free == 61_390_848)          // 3,747 pages: 0.06 GB
        // What the panel printed for the same machine, and why the report said 0.66: the old formula,
        // reproduced here so the regression has a number attached rather than a description.
        let asShipped = b.installed - b.used - b.cached
        #expect(asShipped == 710_639_616)      // 0.66 GB — 11.6x the truth
        #expect(asShipped - b.free == b.reserved)

        // Two-sided, not a literal difference: hw.memsize − hw.memsize_usable is 644,595,712 on this
        // machine, and a few hundred pages caught between queues during a non-atomic read land here
        // too — 284 of them, 4.4 MB, in this sample.
        #expect(b.reserved > 644_595_712)
        #expect(b.reserved < 644_595_712 + 16_777_216)
        #expect(b.app + b.wired + b.compressed + b.cached + b.free + b.reserved == b.installed)
        #expect(b.installed == Self.sixteenGiB)   // the headline still reads "16 GB"
    }

    @Test("speculative pages are counted once — in Cached Files, not also in Free")
    func speculativeIsNotDoubleCounted() {
        // The trap inside the fix. host_statistics64 reports free_count as vm_page_free_count +
        // speculative_count, and those same pages sit inside external_page_count. Taking free_count raw
        // would count them in both Free and Cached Files — 62cf4f1's shape, arrived at by a new route.
        // It is also why vm_stat and a naive reader disagree: vm_stat prints the subtraction already
        // done.
        let counts = VMPageCounts(free: 1_000, speculative: 400, external: 400)
        let b = MemoryBuckets.fromPages(installed: 1 << 30, pages: counts, pageSize: 4_096)
        #expect(b.free == 600 * 4_096)
        #expect(b.cached == 400 * 4_096)      // the speculative pages, here and only here
        #expect(Self.reported.free == UInt64(7_450 - 3_703) * Self.kernelPage)
    }

    // MARK: Page counts → bytes

    @Test("each bucket is its page count times the page size")
    func bucketsConvertPagesToBytes() {
        let b = Self.snapshot()
        #expect(b.installed == Self.sixteenGiB)
        #expect(b.total == Self.sixteenGiB)      // this fixture's pages tile it exactly
        #expect(b.reserved == 0)
        #expect(b.wired == 1_638_400_000)        // 100_000 pages
        #expect(b.compressed == 819_200_000)     //  50_000 pages
        #expect(b.app == 4_587_520_000)          // 280_000 pages: internal minus purgeable
        #expect(b.cached == 3_276_800_000)       // 180_000 external + 20_000 purgeable
        #expect(b.free == 6_857_949_184)         // 418_576 pages, none of them speculative
    }

    @Test("purgeable pages are counted exactly once — out of App, into Cached")
    func purgeableIsNotDoubleCounted() {
        // The subtlety that makes this arithmetic worth testing: purgeable is a SUBSET of internal, so
        // it must leave App Memory and reappear in Cached. App + Cached therefore accounts for internal
        // + external with nothing counted twice and nothing lost.
        let counts = VMPageCounts(free: 0, speculative: 0, internalPages: 100, purgeable: 40, external: 60)
        let b = MemoryBuckets.fromPages(installed: 1 << 30, pages: counts, pageSize: 4_096)
        #expect(b.app == 60 * 4_096)                          // 100 internal − 40 purgeable
        #expect(b.cached == (60 + 40) * 4_096)                // 60 external + the 40 purgeable
        #expect(b.app + b.cached == (100 + 60) * 4_096)
    }

    @Test("swap is carried through untouched")
    func swapPassesThrough() {
        #expect(Self.snapshot(swapUsed: 1_073_741_824).swapUsed == 1_073_741_824)
        #expect(Self.snapshot().swapUsed == 0)
    }

    // MARK: The subtractions that would trap

    @Test("App Memory clamps at zero rather than trapping when purgeable exceeds internal")
    func appMemoryDoesNotUnderflow() {
        // The counts aren't one atomic snapshot, so purgeable CAN briefly read higher than internal.
        // Unsigned `-` traps in Swift, so the unguarded subtraction is a crash rather than the 68 TB
        // App Memory figure ~4 billion wrapped pages would print.
        let counts = VMPageCounts(free: 0, speculative: 0, internalPages: 10, purgeable: 50)
        let b = MemoryBuckets.fromPages(installed: 1 << 30, pages: counts, pageSize: 4_096)
        #expect(b.app == 0)
        #expect(b.cached == 50 * 4_096)   // the purgeable pages still count as reclaimable
    }

    @Test("Free clamps at zero rather than trapping when speculative exceeds free_count")
    func freeDoesNotUnderflow() {
        // Same torn-read argument one bucket over, and new with this rewrite: speculative is a subset of
        // free_count within a single consistent snapshot, but the struct is not filled under a lock.
        let b = MemoryBuckets.fromPages(installed: 1 << 30,
                                        pages: VMPageCounts(free: 10, speculative: 50), pageSize: 4_096)
        #expect(b.free == 0)
    }

    @Test("Reserved clamps at zero when the buckets overlap past the nameplate")
    func reservedDoesNotUnderflow() {
        // A wired anonymous page is counted in both `wired` and `app`, so the buckets can edge past
        // installed. This is where the old Free clamp lived; the subtraction moved, the hazard did not.
        let b = MemoryBuckets(installed: 1000, app: 800, wired: 300, compressed: 0, cached: 100, free: 0)
        #expect(b.used == 1100)
        #expect(b.total == 1200)
        #expect(b.reserved == 0)
        // The boundary a weaker guard would also pass, which CLAUDE.md names as the untested case: a
        // machine with no carveout at all must leave nothing Reserved, not one byte of it.
        let exact = MemoryBuckets(installed: 1200, app: 800, wired: 300, compressed: 0, cached: 100, free: 0)
        #expect(exact.reserved == 0)
        #expect(exact.total == exact.installed)
    }

    // MARK: Fractions

    @Test("fractions are shares of the RAM the VM manages")
    func fractionsAreShares() {
        let b = Self.snapshot()
        // Independent literals, not the code's own expression. `appFraction == Double(app)/Double(total)`
        // is a tautology: it holds whatever `fraction(_:)` divides by, so it would also pass if every
        // fraction read the wrong bucket. All four segments are drawn by MemorySection from these, and
        // they are far enough apart (26.7 / 9.5 / 4.8 / 19.1 %) that a copy-paste picking the wrong field
        // fails loudly rather than shifting a band by a hair.
        #expect(abs(b.appFraction - 0.267029) < 1e-6)
        #expect(abs(b.wiredFraction - 0.095367) < 1e-6)
        #expect(abs(b.compressedFraction - 0.047684) < 1e-6)
        #expect(abs(b.cachedFraction - 0.190735) < 1e-6)
        #expect(abs(b.freeFraction - 0.399185) < 1e-6)
        #expect(abs(b.usedFraction - 0.410080) < 1e-6)
        #expect(abs(b.usagePercent - 41.0080) < 0.0001)
        // The invariant the segmented bar depends on: the five drawn widths tile the track with nothing
        // left over and nothing counted twice. Exact for this fixture — every figure is a whole number of
        // 16 KiB pages against a power-of-two total — so the tolerance is only there for a future one.
        #expect(abs(b.appFraction + b.wiredFraction + b.compressedFraction + b.cachedFraction
                    + b.freeFraction - 1.0) < 1e-12)
        // The pressure ring tracks what can't be reclaimed on demand, so Cached is excluded from it
        // even though it is resident: wired + compressed only.
        #expect(abs(b.pressureFraction - 0.143051) < 1e-6)
    }

    @Test("the rings denominate on managed RAM, not on the nameplate")
    func fractionsExcludeTheCarveout() {
        // The second half of the defect, and the one that reached four surfaces: the usage percentage
        // feeds the ring, the always-visible menu-bar glyph, the hub's RAM row and the VoiceOver label,
        // all from this one ratio. Dividing by the nameplate understated it by a constant 3.9% relative,
        // which put the colour ramp a band late and capped the figure at 96% — it could never read 100%
        // on a machine that was out of memory.
        let b = Self.reported
        #expect(abs(Double(b.used) / Double(b.installed) * 100 - 83.6051) < 0.001)   // what shipped
        #expect(abs(b.usagePercent - 86.8887) < 0.001)                               // what is true
        #expect(b.usagePercent > Double(b.used) / Double(b.installed) * 100)
    }

    @Test("an unread machine yields zeroes instead of dividing by zero")
    func emptySnapshotIsSafe() {
        // total == 0 is what a failed host_statistics64 leaves behind, and the views draw the rings
        // from these fractions before the first successful read lands.
        let b = MemoryBuckets()
        #expect(b.total == 0)
        #expect(b.reserved == 0)
        #expect(b.free == 0)
        #expect(b.usedFraction == 0)
        #expect(b.usagePercent == 0)
        #expect(b.appFraction == 0)
        #expect(b.freeFraction == 0)
        #expect(b.pressureFraction == 0)
    }
}
