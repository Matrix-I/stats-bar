// MemoryStats.swift — reads live physical-RAM usage from the Mach VM statistics
// (host_statistics64 + HOST_VM_INFO64) and swap from sysctl vm.swapusage, and maps them onto the
// same App / Wired / Compressed / Free buckets macOS Activity Monitor shows. No root needed.
//
// Page counts come back in units of vm_kernel_page_size (16 KiB on Apple Silicon, 4 KiB on Intel —
// the same size `vm_stat` prints), so that's the multiplier used to turn pages into bytes. Total is
// taken from ProcessInfo.physicalMemory (exact hw.memsize) rather than summing pages, so the
// bar's Free remainder is precise.

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

        let page = Double(vm_kernel_page_size)
        var info = MemoryInfo()
        info.total = total
        info.wired = bytes(stats.wire_count, page)
        info.compressed = bytes(stats.compressor_page_count, page)
        // App Memory = resident anonymous pages that aren't purgeable. purgeable is a subset of
        // internal, but guard the subtraction so a transient race can't underflow the UInt32.
        let appPages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        info.app = UInt64(max(0, appPages) * page)

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            info.swapUsed = swap.xsu_used
        }

        return info
    }

    private static func bytes(_ pages: natural_t, _ pageSize: Double) -> UInt64 {
        UInt64(Double(pages) * pageSize)
    }
}
