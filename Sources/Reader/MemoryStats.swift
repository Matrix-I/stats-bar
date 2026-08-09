// MemoryStats.swift — reads live physical-RAM usage from the Mach VM statistics
// (host_statistics64 + HOST_VM_INFO64) and swap from sysctl vm.swapusage, and maps them onto the
// same App / Wired / Compressed / Free buckets macOS Activity Monitor shows. No root needed.
//
// Page counts come back in units of vm_kernel_page_size (16 KiB on Apple Silicon, 4 KiB on Intel —
// the same size `vm_stat` prints), so that's the multiplier used to turn pages into bytes.
//
// ProcessInfo.physicalMemory (exact hw.memsize) is passed as `installed` — the nameplate — and NOT as
// the figure the buckets are measured against. It used to be both, on the reasoning that taking the
// exact hardware total made the bar's Free remainder precise. That reasoning is backwards, and it is
// the bug MemoryBuckets was rewritten for: hw.memsize includes a firmware carveout the page counters
// never report, so making Free the remainder of it made Free precisely wrong by the size of the
// carveout. Every bucket is now read from the page counts, Free included; see MemoryBuckets.

import Foundation

enum MemoryStats {
    static func read() -> MemoryInfo? {
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride
                                           / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        // host_statistics64 counts KERNEL pages, so ask the kernel for its page size rather than
        // using getpagesize()/vm_page_size (the *process* page size). They agree on native arm64 and
        // x86_64, but a translated process reports 4 KiB while the kernel counts 16 KiB pages, which
        // would under-report every bucket by 4×.
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        var swapUsed: UInt64 = 0
        if let swap: xsw_usage = Sysctl.value("vm.swapusage") {
            swapUsed = swap.xsu_used
        }

        // Everything from here on is arithmetic, and it lives in MemoryBuckets (Sources/Core) where it
        // is unit-tested. This function's job is only to gather the four numbers it needs.
        var info = MemoryInfo()
        info.buckets = MemoryBuckets.fromPages(
            installed: total,
            pages: VMPageCounts(free: stats.free_count,
                                speculative: stats.speculative_count,
                                wired: stats.wire_count,
                                compressed: stats.compressor_page_count,
                                internalPages: stats.internal_page_count,
                                purgeable: stats.purgeable_count,
                                external: stats.external_page_count),
            pageSize: UInt64(pageSize),
            swapUsed: swapUsed
        )
        return info
    }
}
