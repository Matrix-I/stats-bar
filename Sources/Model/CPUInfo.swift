// CPUInfo.swift — live CPU model: overall System/User/Idle load, per-cluster (efficiency vs
// performance) averages, average die temperature, and uptime. Populated by CPUReader from the
// Mach host statistics (host_processor_info), the AppleSMC temperature sensors, and sysctl.

import Foundation

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

    var coreCount = 0
    var efficiencyCoreCount = 0
    var performanceCoreCount = 0

    // Average CPU-die temperature in °C, or nil when no sensor is readable (SMC unavailable, or a
    // chip that exposes none of the keys we probe).
    var temperatureC: Double? = nil

    // Seconds since the machine last booted.
    var uptimeSeconds: Double = 0

    /// The figure shown in the usage ring and menu bar: everything that isn't idle.
    var usagePercent: Double { max(0, min(100, 100 - idlePercent)) }
}
