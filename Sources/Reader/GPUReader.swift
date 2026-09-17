// GPUReader.swift — the ObservableObject behind the GPU menu-bar item. Two sources, both cheap:
//   • The IOAccelerator registry entries — one IORegistryEntryCreateCFProperties per GPU, giving the
//     driver's live "PerformanceStatistics" dictionary plus the fixed model name and core count.
//     This is an instantaneous snapshot the driver maintains, NOT a delta the app has to compute, so
//     unlike the CPU's tick counters there is no baseline to keep and no first-tick blind spot.
//   • IOReport's cumulative GPU energy counter, for the watts row (see GPUPowerMeter).
//
// Matching on "IOAccelerator" rather than on the concrete driver class is what makes this portable:
// the entry on this machine is an AGXAcceleratorG13X and on the next Apple GPU it will be something
// else, but every one of them — Apple, Intel and AMD alike — is an IOAccelerator subclass, which is
// why `ioreg -rc IOAccelerator` finds the AGX node here.
//
// Like the other readers, the expensive half is gated on someone looking: the registry snapshot runs
// whenever the menu-bar glyph is visible (it is the glyph's only input), while the IOReport
// subscription is sampled only while the popover is open.

import Foundation
import Combine
import IOKit

@MainActor
final class GPUReader: ObservableObject {
    @Published var info = GPUInfo()

    private lazy var poll = PollingTimer { [weak self] in self?.refresh() }
    private var panelOpen = false
    private var itemVisible = true
    private let power = GPUPowerMeter()

    /// Held across ticks rather than rebuilt from `info`, so a tick that fails to read the registry
    /// leaves the chart showing what it had instead of dropping a notch to zero.
    private var history = UsageHistory(capacity: GPUInfo.historyCapacity)

    private static let idleInterval: TimeInterval = 2    // menu-bar % only
    private static let activeInterval: TimeInterval = 1  // live readout while the panel is open
    /// Low Power Mode: back off the menu-bar-only poll, matching CPUReader — the user has asked macOS
    /// to trade responsiveness for battery and a background sampler should take the hint.
    private static let lowPowerIdleInterval: TimeInterval = 5

    private var powerObserver: NSObjectProtocol?

    init() {
        applyCadence()
        refresh()
        powerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyCadence(); self?.refresh() }
        }
    }

    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        applyCadence()
        if open {
            // The energy counter only accumulates into a delta while it is being sampled, so the
            // baseline is stale between popover sessions — re-prime it rather than reporting the
            // average draw over however long the panel was shut.
            power.resetBaseline()
            refresh()
        }
    }

    func setItemVisible(_ visible: Bool) {
        guard visible != itemVisible else { return }
        itemVisible = visible
        applyCadence()
        if visible && !panelOpen { refresh() }
    }

    private func applyCadence() {
        if panelOpen { poll.schedule(every: Self.activeInterval) }
        else if itemVisible {
            poll.schedule(every: ProcessInfo.processInfo.isLowPowerModeEnabled
                          ? Self.lowPowerIdleInterval : Self.idleInterval)
        }
        else { poll.stop() }
    }

    func refresh() {
        // Nothing displays the GPU when the popover is closed and the item is hidden — skip the read.
        guard panelOpen || itemVisible else { return }

        var out = GPUInfo()
        out.devices = Self.readDevices()

        // Only a real reading advances the chart. A tick that found no accelerator appends nothing,
        // so an unreadable moment leaves a flat gap in the series rather than a dive to zero that
        // would read as an idle GPU.
        if let util = out.devices.first?.stats.deviceUtilization { history.append(util) }
        out.history = history

        // Watts are popover-only: the glyph doesn't show them, and the subscription is the one part
        // of this reader that costs more than a single registry read.
        if panelOpen, power.isAvailable { out.powerWatts = power.sample() ?? info.powerWatts }

        info = out
    }

    // MARK: - Registry

    /// Every accelerator the registry lists, in enumeration order.
    private static func readDevices() -> [GPUDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var out: [GPUDevice] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }
            var ref: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &ref, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = ref?.takeRetainedValue() as? [String: Any] else { continue }

            let stats = props["PerformanceStatistics"] as? [String: Any] ?? [:]
            out.append(GPUDevice(id: entryID,
                                 name: name(props, service: service),
                                 coreCount: (props["gpu-core-count"] as? NSNumber)?.intValue,
                                 stats: GPUStatistics.parse(stats)))
        }
        return out
    }

    /// The driver's marketing `model`, falling back to the registry entry's own name ("AGXAcceleratorG13X").
    /// The fallback is ugly but it is the truth; inventing "Graphics" would make two different GPUs on
    /// a dual-GPU machine indistinguishable in the list.
    private static func name(_ props: [String: Any], service: io_object_t) -> String {
        if let model = props["model"] as? String, !model.isEmpty { return model }
        // Some drivers publish `model` as raw bytes (a device-tree string, NUL-terminated) rather
        // than as a CFString.
        if let data = props["model"] as? Data,
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
           !s.isEmpty { return s }
        var raw = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(service, &raw) == KERN_SUCCESS else { return "GPU" }
        let n = String(cString: raw)
        return n.isEmpty ? "GPU" : n
    }
}
