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
    /// The tick-delta load and everything derived from it. Lives in Sources/Core (CPULoad) so it can be
    /// unit-tested — this type can't be, since ProcessSample pulls in AppKit.
    var load = CPULoad()

    var coreCount = 0
    var efficiencyCoreCount = 0
    var performanceCoreCount = 0

    // Marketing name of the chip, from sysctl machdep.cpu.brand_string (e.g. "Apple M1 Pro").
    // nil when the key is unreadable.
    var chipName: String? = nil

    // Average CPU-die temperature in °C, or nil when no sensor is readable (SMC unavailable, or a
    // chip that exposes none of the keys we probe).
    var temperatureC: Double? = nil

    // Die temperature of each CPU thermal zone, in SMC key order — the spread `temperatureC`
    // averages away. NOT indexed by logical core, however much the CORES grid pairs them off by
    // position: the zone count follows the DIE, not the bin (10 sites on an M1 Pro whether the chip
    // ships as an 8- or 10-core), and the SMC publishes nothing saying which zone hosts which core.
    // Measurement rules out both obvious guesses — six busy performance cores heated zones 0, 1, 3,
    // 5, 6 and 8 by 16–19 °C while the rest moved 11–13 °C, which is neither the contiguous 2…7 that
    // logical-core order predicts nor the 2,3,4,6,7,8 that the device tree's physical cpu-ids do.
    // CPUSection.cores documents why pairing by position is still the right call. Empty until the
    // popover has been open for a tick (see CPUReader.refresh).
    var coreTemperaturesC: [Double] = []

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

    // Read-only forwards, so the panels, the Control Center tiles and the menu-bar label keep reading
    // `info.usagePercent` rather than `info.load.usagePercent`. Nothing is computed here: each of these
    // is CPULoad's own property, and that is the only place the arithmetic exists.
    var systemPercent: Double       { load.systemPercent }
    var userPercent: Double         { load.userPercent }
    var idlePercent: Double         { load.idlePercent }
    var efficiencyPercent: Double?  { load.efficiencyPercent }
    var performancePercent: Double? { load.performancePercent }
    var perCoreBusy: [Double]       { load.perCoreBusy }
    var usagePercent: Double        { load.usagePercent }
}
