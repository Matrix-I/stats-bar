// CPUInfo.swift — live CPU model: overall System/User/Idle load, per-cluster (efficiency vs
// performance) averages, average die temperature, and uptime. Populated by CPUReader from the
// Mach host statistics (host_processor_info), the AppleSMC temperature sensors, and sysctl.

import Foundation
import AppKit

/// One row of the TOP PROCESSES table: a process's display name, app icon (nil for daemons/helpers
/// that own no NSRunningApplication) and its CPU share (as reported by `ps`, a decaying average, so
/// it can momentarily exceed 100 % across multiple cores).
struct ProcessSample: Identifiable {
    let pid: Int
    let name: String
    let cpuPercent: Double
    let icon: NSImage?
    var id: Int { pid }
}

struct CPUInfo {
    // Overall load, as a share of total CPU ticks in the last sampling window (0…100).
    // `user` folds in nice (scheduler-niced user time), matching how Activity Monitor / Stats
    // present it, so system + user + idle ≈ 100.
    var systemPercent = 0.0
    var userPercent = 0.0
    var idlePercent = 100.0

    // Average busy% of each core cluster. nil until the first delta is available, or when the
    // machine has no such cluster (e.g. an Intel Mac with a single performance level).
    var efficiencyPercent: Double? = nil
    var performancePercent: Double? = nil

    // Busy% of every logical core, in host_processor_info order — efficiency cores occupy the low
    // indices, performance cores follow (CPUReader documents how that was verified). Empty until the
    // first tick delta is available. This is the array the cluster averages above are reduced from,
    // so publishing it costs no extra sampling.
    var perCoreBusy: [Double] = []

    var coreCount = 0
    var efficiencyCoreCount = 0
    var performanceCoreCount = 0

    // Marketing name of the chip, from sysctl machdep.cpu.brand_string (e.g. "Apple M1 Pro").
    // nil when the key is unreadable.
    var chipName: String? = nil

    // Average CPU-die temperature in °C, or nil when no sensor is readable (SMC unavailable, or a
    // chip that exposes none of the keys we probe).
    var temperatureC: Double? = nil

    // Seconds since the machine last booted.
    var uptimeSeconds: Double = 0

    // System-wide thermal pressure (ProcessInfo.thermalState). Event-driven, not polled: macOS posts
    // thermalStateDidChangeNotification, so this costs nothing while the machine stays cool.
    var thermalState: ProcessInfo.ThermalState = .nominal

    // Whether macOS Low Power Mode is on. Also drives CPUReader's idle poll cadence.
    var lowPowerMode = false

    // 1-, 5- and 15-minute load averages, ALREADY divided by the logical core count. Normalised on
    // purpose: a raw 8.0 is full utilisation on an 8-core and 2× oversubscription on a 4-core, so the
    // unnormalised number reads like an alarm on one machine and a shrug on another. Empty when the
    // kernel doesn't answer.
    var loadAverage: [Double] = []

    // The heaviest CPU consumers right now (from `ps`, refreshed a little slower than the load).
    var topProcesses: [ProcessSample] = []

    // Active-residency-weighted average clock speed (MHz) per cluster, from IOReport. nil when the
    // private framework / DVFS tables aren't available (e.g. Intel, or a future macOS).
    var allFrequencyMHz: Double? = nil
    var efficiencyFrequencyMHz: Double? = nil
    var performanceFrequencyMHz: Double? = nil

    /// The figure shown in the usage ring and menu bar: everything that isn't idle.
    var usagePercent: Double { max(0, min(100, 100 - idlePercent)) }
}
