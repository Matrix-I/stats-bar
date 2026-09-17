// GPUInfo.swift — live GPU model: every accelerator the machine exposes, the primary one's recent
// utilisation history, and the GPU's power draw. Populated by GPUReader from the IOAccelerator
// registry entries and the IOReport "Energy Model" group.

import Foundation

/// One accelerator, as the IOKit registry describes it.
struct GPUDevice: Identifiable, Equatable {
    /// The IORegistry entry ID — stable for the life of the boot, which is what makes it safe to key
    /// a ForEach on. The index in the array is not: an eGPU unplugged mid-session renumbers it.
    let id: UInt64
    /// Marketing name from the driver's `model` key, e.g. "Apple M1 Pro". Falls back to the registry
    /// entry name when a driver publishes none.
    let name: String
    /// Shader cores from `gpu-core-count`. nil on the drivers that don't publish it — every
    /// non-Apple one, so far as this machine can show.
    let coreCount: Int?
    var stats: GPUStatistics
}

struct GPUInfo {
    /// In registry-enumeration order. Empty when no accelerator could be read at all, which is the
    /// case the panel reports rather than papering over with zeroes.
    var devices: [GPUDevice] = []

    /// Whole-GPU power draw in watts, from the cumulative energy counter (see GPUPowerMeter). nil
    /// while the popover is closed — the counter is only subscribed to while someone is looking —
    /// and on any machine whose IOReport surface doesn't carry the channel.
    var powerWatts: Double? = nil

    /// Recent `deviceUtilization` readings for the primary GPU, oldest first. See UsageHistory for
    /// why the window is counted in samples rather than seconds.
    var history = UsageHistory(capacity: GPUInfo.historyCapacity)

    static let historyCapacity = 60

    /// The GPU the rings, the history chart and the menu-bar glyph describe. Registry order rather
    /// than a "which one is active" judgement: on Apple Silicon there is exactly one accelerator, and
    /// on the dual-GPU Intel machines where the question is real, nothing in the registry answers it
    /// — so the others are listed in DETAILS instead of one being silently picked as the truth.
    var primary: GPUDevice? { devices.first }

    /// The figure on the menu-bar glyph. 0 rather than nil when there is no reading, matching
    /// CPUInfo.usagePercent — the glyph has to draw *something*, and the panel is where "no reading"
    /// is actually said.
    var usagePercent: Double { primary?.stats.deviceUtilization ?? 0 }
}
