// CPUReader.swift — the ObservableObject behind the CPU menu-bar item. It publishes a live
// CPUInfo built from three sources, all cheap enough to run on the main thread at ~1 Hz:
//   • host_processor_info(PROCESSOR_CPU_LOAD_INFO) — per-core tick counters. Usage is the DELTA
//     between two samples (busy ticks ÷ total ticks), so a previous snapshot is kept between ticks.
//   • The AppleSMC CPU-die temperature sensors (discovered once at startup — see SMC.allKeyNames).
//   • sysctl — the fixed core topology (how many efficiency vs performance cores) and boot time.
//
// Efficiency vs performance split: on Apple Silicon host_processor_info enumerates the efficiency
// cores at the LOW indices (0 ..< eCoreCount) and the performance cores after them — verified on
// this M1 Pro by pinning QoS-.background spinners (which the scheduler confines to efficiency
// cores) and watching exactly cores 0–1 peg. sysctl hw.perflevel1.logicalcpu gives the efficiency
// count, hw.perflevel0.logicalcpu the performance count.
//
// Like the other readers, work is gated on the popover being open only where it costs something:
// the SMC temperature read is skipped while closed (the menu bar only needs the usage %), but the
// load sample always runs so the menu-bar percentage stays live.

import Foundation
import Combine

final class CPUReader: ObservableObject {
    @Published var info = CPUInfo()

    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var panelOpen = false
    private let smc = SMC()

    // Previous per-core [user, system, idle, nice] tick counts, for the delta computation.
    private var prevTicks: [[UInt32]]? = nil

    // Fixed for the machine's lifetime.
    private let eCoreCount: Int   // efficiency cores (perflevel1) — the low indices
    private let pCoreCount: Int   // performance cores (perflevel0)
    private let tempKeys: [String]

    private static let idleInterval: TimeInterval = 2   // menu-bar % only
    private static let activeInterval: TimeInterval = 1 // live readout while the panel is open

    init() {
        eCoreCount = Self.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        pCoreCount = Self.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        tempKeys = Self.discoverTemperatureKeys(smc)

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

    /// Poll once a second while the panel is visible (and read temperature); drop back to the lazy
    /// menu-bar-only cadence when it closes.
    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        schedule(open ? Self.activeInterval : Self.idleInterval)
        if open { refresh() }
    }

    func refresh() {
        guard let cur = sampleTicks() else { return }

        var out = CPUInfo()
        out.coreCount = cur.count
        out.efficiencyCoreCount = eCoreCount
        out.performanceCoreCount = pCoreCount
        out.uptimeSeconds = Self.uptime()

        if let prev = prevTicks, prev.count == cur.count {
            let U = Int(CPU_STATE_USER), S = Int(CPU_STATE_SYSTEM), I = Int(CPU_STATE_IDLE), N = Int(CPU_STATE_NICE)
            var sumUser = 0.0, sumSys = 0.0, sumIdle = 0.0, sumTotal = 0.0
            var perCoreBusy = [Double](repeating: 0, count: cur.count)

            for c in 0..<cur.count {
                let du = Double(cur[c][U] &- prev[c][U])
                let ds = Double(cur[c][S] &- prev[c][S])
                let dn = Double(cur[c][N] &- prev[c][N])
                let di = Double(cur[c][I] &- prev[c][I])
                let total = du + ds + dn + di
                sumUser += du + dn   // fold nice into user
                sumSys += ds
                sumIdle += di
                sumTotal += total
                perCoreBusy[c] = total > 0 ? (du + ds + dn) / total * 100 : 0
            }

            if sumTotal > 0 {
                out.userPercent = sumUser / sumTotal * 100
                out.systemPercent = sumSys / sumTotal * 100
                out.idlePercent = sumIdle / sumTotal * 100
            }

            // Efficiency cores are the low indices [0, eCoreCount); performance cores follow.
            if eCoreCount > 0, eCoreCount <= cur.count {
                out.efficiencyPercent = perCoreBusy[0..<eCoreCount].reduce(0, +) / Double(eCoreCount)
            }
            if pCoreCount > 0, eCoreCount + pCoreCount <= cur.count {
                out.performancePercent = perCoreBusy[eCoreCount..<(eCoreCount + pCoreCount)].reduce(0, +) / Double(pCoreCount)
            }
        }
        prevTicks = cur

        // Temperature only matters inside the popover — skip the SMC reads while it's closed.
        if panelOpen, !tempKeys.isEmpty {
            let vals = tempKeys.compactMap { smc.readFloat($0) }.filter { $0 > 0 && $0 < 130 }
            if !vals.isEmpty { out.temperatureC = vals.reduce(0, +) / Double(vals.count) }
        }

        info = out
    }

    // MARK: - Sampling

    /// Per-core tick counters as [core][CPU_STATE_*]. Frees the kernel-allocated array via vm_deallocate.
    private func sampleTicks() -> [[UInt32]]? {
        var count = natural_t(0)
        var infoArray: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &count, &infoArray, &infoCount) == KERN_SUCCESS,
              let infoArray else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let buf = UnsafeBufferPointer(start: infoArray, count: Int(infoCount))
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            (0..<states).map { UInt32(bitPattern: buf[core * states + $0]) }
        }
    }

    // MARK: - One-off discovery

    /// The CPU-die temperature keys this chip exposes. Apple Silicon names them in the 4-char "Tp.."
    /// family (the performance-core die sensors, all `flt`); an Intel Mac exposes a handful of the
    /// classic TC** keys instead. Probed once at startup so the per-second read only touches keys
    /// that exist.
    private static func discoverTemperatureKeys(_ smc: SMC) -> [String] {
        let all = smc.allKeyNames()
        let apple = all.filter { $0.count == 4 && $0.hasPrefix("Tp") }
        if !apple.isEmpty { return apple.sorted() }
        let intel = ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TC1C", "TC2C", "TC3C", "TC4C", "TCXC", "TCAD"]
        return intel.filter { smc.readFloat($0) != nil }
    }

    // MARK: - sysctl helpers

    private static func sysctlInt(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        if size == 4 {
            var v: UInt32 = 0
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
            return Int(v)
        }
        var v = 0
        var s = MemoryLayout<Int>.size
        guard sysctlbyname(name, &v, &s, nil, 0) == 0 else { return nil }
        return v
    }

    private static func uptime() -> Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec != 0 else { return 0 }
        let boot = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        return max(0, Date().timeIntervalSince1970 - boot)
    }
}
