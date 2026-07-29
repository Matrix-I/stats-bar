// MemoryBucketsTests.swift — the RAM arithmetic, which is the only part of this repo with TWO shipped
// bugs in its history (62cf4f1 and 827d7e7). Both printed believable gigabytes while being wrong, so
// the cases below are written to reproduce each one specifically rather than to describe the code.
//
// The numbers are a realistic 16 GiB M1 Pro at 16 KiB kernel pages, so the figures that appear in the
// assertions are the ones that would appear in the panel.

import Testing
@testable import StatsBarCore

@Suite("Memory buckets")
struct MemoryBucketsTests {

    static let sixteenGiB: UInt64 = 17_179_869_184
    static let kernelPage: UInt64 = 16_384   // Apple Silicon

    /// A plausible mid-session snapshot.
    static let pages = VMPageCounts(wired: 100_000,
                                    compressed: 50_000,
                                    internalPages: 300_000,
                                    purgeable: 20_000,
                                    external: 180_000)

    static func snapshot(pageSize: UInt64 = kernelPage, swapUsed: UInt64 = 0) -> MemoryBuckets {
        MemoryBuckets.fromPages(total: sixteenGiB, pages: pages,
                                pageSize: pageSize, swapUsed: swapUsed)
    }

    // MARK: The two bugs this file exists for

    @Test("reclaimable file pages land in Cached, not in Free — the 3.2 GB over-report")
    func cachedFilesAreNotCountedAsFree() {
        let b = Self.snapshot()
        // What the bug did: subtract only `used` from total, leaving every reclaimable file page sitting
        // in Free. The gap between that and the truth is the whole Cached bucket — 3.28 GB here, which
        // is the same order as the 3.2 GB measured on the real machine.
        let freeAsTheBugComputedIt = Self.sixteenGiB - b.used
        #expect(b.free == 6_857_949_184)
        #expect(freeAsTheBugComputedIt - b.free == b.cached)
        #expect(b.cached == 3_276_800_000)
    }

    @Test("bucket sizes scale with the page size they are given")
    func pageSizeIsLoadBearing() {
        // The other bug: host_statistics64 counts KERNEL pages, but the code sized them with the
        // PROCESS page size. The two agree natively and differ 4× in a translated process, which
        // under-reported every bucket by 4× — visible only as "my Mac says it's using 2 GB".
        let kernel = Self.snapshot(pageSize: 16_384)
        let process = Self.snapshot(pageSize: 4_096)
        #expect(kernel.app == process.app * 4)
        #expect(kernel.wired == process.wired * 4)
        #expect(kernel.compressed == process.compressed * 4)
        #expect(kernel.cached == process.cached * 4)
    }

    // MARK: Page counts → bytes

    @Test("each bucket is its page count times the page size")
    func bucketsConvertPagesToBytes() {
        let b = Self.snapshot()
        #expect(b.total == Self.sixteenGiB)
        #expect(b.wired == 1_638_400_000)        // 100_000 pages
        #expect(b.compressed == 819_200_000)     //  50_000 pages
        #expect(b.app == 4_587_520_000)          // 280_000 pages: internal minus purgeable
        #expect(b.cached == 3_276_800_000)       // 180_000 external + 20_000 purgeable
    }

    @Test("purgeable pages are counted exactly once — out of App, into Cached")
    func purgeableIsNotDoubleCounted() {
        // The subtlety that makes this arithmetic worth testing: purgeable is a SUBSET of internal, so
        // it must leave App Memory and reappear in Cached. App + Cached therefore accounts for internal
        // + external with nothing counted twice and nothing lost.
        let pages = VMPageCounts(internalPages: 100, purgeable: 40, external: 60)
        let b = MemoryBuckets.fromPages(total: 1 << 30, pages: pages, pageSize: 4_096)
        #expect(b.app == 60 * 4_096)                          // 100 internal − 40 purgeable
        #expect(b.cached == (60 + 40) * 4_096)                // 60 external + the 40 purgeable
        #expect(b.app + b.cached == (100 + 60) * 4_096)
    }

    @Test("App Memory clamps at zero rather than trapping when purgeable exceeds internal")
    func appMemoryDoesNotUnderflow() {
        // The counts aren't one atomic snapshot, so purgeable CAN briefly read higher than internal.
        // Unsigned `-` traps in Swift, so the unguarded subtraction is a crash rather than the 68 TB
        // App Memory figure ~4 billion wrapped pages would print.
        let pages = VMPageCounts(internalPages: 10, purgeable: 50)
        let b = MemoryBuckets.fromPages(total: 1 << 30, pages: pages, pageSize: 4_096)
        #expect(b.app == 0)
        #expect(b.cached == 50 * 4_096)   // the purgeable pages still count as reclaimable
    }

    @Test("swap is carried through untouched")
    func swapPassesThrough() {
        #expect(Self.snapshot(swapUsed: 1_073_741_824).swapUsed == 1_073_741_824)
        #expect(Self.snapshot().swapUsed == 0)
    }

    // MARK: used / free

    @Test("Used is App plus Wired plus Compressed, and the five buckets account for all of RAM")
    func usedAndFreePartitionTotal() {
        let b = Self.snapshot()
        #expect(b.used == b.app + b.wired + b.compressed)
        #expect(b.used == 7_045_120_000)
        // The invariant the panel's segmented bar depends on: nothing unaccounted for, nothing twice.
        #expect(b.app + b.wired + b.compressed + b.cached + b.free == b.total)
    }

    @Test("Free clamps at zero when the buckets overlap past total")
    func freeDoesNotUnderflow() {
        // A wired anonymous page is counted in both `wired` and `app`, so used + cached can edge past
        // total. Unguarded, the UInt64 subtraction traps and takes the app down mid-refresh.
        let b = MemoryBuckets(total: 1000, app: 800, wired: 300, compressed: 0, cached: 100)
        #expect(b.used == 1100)
        #expect(b.free == 0)
    }

    // MARK: Fractions

    @Test("fractions are shares of physical RAM")
    func fractionsAreShares() {
        let b = Self.snapshot()
        #expect(abs(b.usedFraction - 0.410080) < 0.000001)
        #expect(abs(b.usagePercent - 41.0080) < 0.0001)
        #expect(abs(b.appFraction - Double(b.app) / Double(b.total)) < 1e-12)
        #expect(abs(b.cachedFraction - Double(b.cached) / Double(b.total)) < 1e-12)
        // The pressure ring tracks what can't be reclaimed on demand, so Cached is excluded from it
        // even though it is resident.
        #expect(abs(b.pressureFraction
                    - Double(b.wired + b.compressed) / Double(b.total)) < 1e-12)
    }

    @Test("an unread machine yields zeroes instead of dividing by zero")
    func emptySnapshotIsSafe() {
        // total == 0 is what a failed host_statistics64 leaves behind, and the views draw the rings
        // from these fractions before the first successful read lands.
        let b = MemoryBuckets()
        #expect(b.free == 0)
        #expect(b.usedFraction == 0)
        #expect(b.usagePercent == 0)
        #expect(b.appFraction == 0)
        #expect(b.pressureFraction == 0)
    }
}
