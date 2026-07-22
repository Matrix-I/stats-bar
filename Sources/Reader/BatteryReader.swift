// BatteryReader.swift — reads the Mac's battery straight from the IOKit "AppleSmartBattery"
// registry (the same source coconutBattery uses — no root, no kernel extension) plus the live
// SMC power rails, and publishes a BatteryInfo on the main thread.

import Foundation
import Combine
import IOKit
import IOKit.ps

final class BatteryReader: ObservableObject {
    @Published var info = BatteryInfo()
    private lazy var poll = PollingTimer { [weak self] in self?.refresh() }
    private var panelOpen = false
    private let smc = SMC.shared

    /// Power-source change notifications (plug/unplug, charging state, charge %) trigger an immediate
    /// refresh, so the menu-bar glyph reacts at once even though the closed-panel poll is slow — that's
    /// what lets idleInterval be lazy without the charging bolt / % lagging behind reality. Retained so
    /// it can be removed in deinit.
    private var powerSourceMonitor: CFRunLoopSource?

    // "Maximum Capacity" (macOS's own battery-health figure — System Information / Battery Health)
    // has no public IOKit key: Apple computes it with a private, smoothed algorithm that no raw
    // ratio reproduces. So we read the exact value macOS reports from `system_profiler`, but only
    // every few minutes on a background queue — battery health drifts over weeks, never per-second,
    // so the 1 Hz gauge path below never pays that cost. cachedMaxCapacity is touched on main only.
    private var cachedMaxCapacity: Int?
    private lazy var healthRead = ThrottledBackgroundValue<Int?>(label: "BatteryReader.health", every: 300)

    // Closed popover: a slow backstop poll — the full IOKit property-dict read is materialized every
    // tick, so doing it once a second all day (86,400×) for a glyph whose charge % moves ~once a
    // minute is wasteful. Power-source notifications (see startPowerSourceMonitor) cover the changes
    // that actually matter for the glyph, so the poll only needs to catch the rest occasionally.
    private static let idleInterval: TimeInterval = 10
    private static let activeInterval: TimeInterval = 1  // live readout while the detail panel is open

    init() {
        refresh()
        poll.schedule(every: Self.idleInterval)
        startPowerSourceMonitor()
    }

    /// Refresh the instant the power source changes (charger plugged/unplugged, charging↔not, a new
    /// charge %), so the menu-bar glyph stays live between the lazy idle polls. The C callback can't
    /// capture, so `self` is passed through the context pointer (unretained — BatteryReader lives for
    /// the whole app run, owned by AppDelegate). The source is added to the main run loop, so the
    /// callback fires on main and refresh() stays main-thread-only like every other call site.
    private func startPowerSourceMonitor() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryReader>.fromOpaque(ctx).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceMonitor = source
    }

    deinit {
        if let source = powerSourceMonitor {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    /// Poll once a second while the detail panel is visible; drop back to the lazy cadence when it closes.
    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        poll.schedule(every: open ? Self.activeInterval : Self.idleInterval)
        if open { refresh() }
    }

    func refresh() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef,
                                                kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { return }

        var i = BatteryInfo()
        i.deviceName = props["DeviceName"] as? String ?? "Battery"
        i.serial = props["Serial"] as? String ?? ""
        i.designCapacity = intOf(props["DesignCapacity"])

        // Apple Silicon: AppleRaw* holds the real mAh values; older Intel: fall back to Max/CurrentCapacity
        i.maxCapacity = intOf(props["AppleRawMaxCapacity"])
        if i.maxCapacity == 0 { i.maxCapacity = intOf(props["MaxCapacity"]) }
        i.currentCapacity = intOf(props["AppleRawCurrentCapacity"])
        if i.currentCapacity == 0 { i.currentCapacity = intOf(props["CurrentCapacity"]) }

        // State of Charge — the calibrated 0–100 % macOS reports (System Information's
        // "State of Charge (%)"), NOT the raw mAh ratio above. On Apple Silicon the relative
        // "CurrentCapacity"/"MaxCapacity" keys are already percentages (MaxCapacity == 100,
        // CurrentCapacity == the SoC, which the gauge pins to 100 at full); on Intel they hold
        // mAh and the ratio yields the same percentage. Falls back to the raw mAh ratio only if
        // the relative max is somehow absent.
        let relMax = intOf(props["MaxCapacity"])
        let relCurrent = intOf(props["CurrentCapacity"])
        if relMax > 0 {
            i.stateOfCharge = min(100, Double(relCurrent) / Double(relMax) * 100)
        } else if i.maxCapacity > 0 {
            i.stateOfCharge = min(100, Double(i.currentCapacity) / Double(i.maxCapacity) * 100)
        }

        i.cycleCount = intOf(props["CycleCount"])
        i.temperatureC = Double(intOf(props["Temperature"])) / 100.0
        i.voltageV = Double(intOf(props["Voltage"])) / 1000.0
        i.amperageA = Double(signedIntOf(props["Amperage"])) / 1000.0
        i.isCharging = props["IsCharging"] as? Bool ?? false
        i.externalConnected = props["ExternalConnected"] as? Bool ?? false
        i.fullyCharged = props["FullyCharged"] as? Bool ?? false
        i.timeToEmpty = intOf(props["AvgTimeToEmpty"])
        i.timeToFull = intOf(props["AvgTimeToFull"])

        if let ad = props["AdapterDetails"] as? [String: Any] {
            i.adapterWatts = intOf(ad["Watts"])
            i.adapterName = (ad["Name"] as? String)
                ?? (ad["Description"] as? String) ?? ""
        }

        // DC in — total power the machine is drawing from the charger (Apple Silicon: BatteryData.AdapterPower)
        if let bd = props["BatteryData"] as? [String: Any],
           let p = bd["AdapterPower"] as? NSNumber {
            i.adapterPower = p.doubleValue
        }

        // Live SMC power rails + fan speeds (these move every second — see the header note on
        // BatteryInfo). They are detail-panel-only content, so skip the SMC user-client round-trips
        // while the panel is closed — the menu-bar glyph needs only the IOKit charge fields read
        // above. Matches the popover-gating every other reader does (cf. CPUReader's temperature read).
        if panelOpen {
            i.smcSystemTotalW  = smc.readFloat("PSTR")
            i.smcDCInW         = smc.readFloat("PDTR")
            i.smcBrightnessW   = smc.readFloat("PDBR")
            i.smcThunderboltLW = smc.readFloat("PU1R")
            i.smcThunderboltRW = smc.readFloat("PU2R")
            i.smcPPBRW         = smc.readFloat("PPBR")
            i.fans = smc.readFans()
        }

        // macOS's own "Maximum Capacity" — refreshed at most every few minutes, off the main
        // thread (see the note on the cache fields above). Publish the last value we have.
        maybeReadMaximumCapacity()
        i.maximumCapacityPercent = cachedMaxCapacity

        // refresh() only ever runs on the main thread (init / setPanelOpen / the main-run-loop poll),
        // so publish directly rather than hopping to the next run-loop pass.
        info = i
    }

    /// Refresh macOS's "Maximum Capacity" at most every few minutes, off the main thread. Called from
    /// `refresh()` (main); the read runs on a background queue and the result lands back on main, so
    /// cachedMaxCapacity is only ever touched there. Nil reads are ignored (keep the last value).
    private func maybeReadMaximumCapacity() {
        healthRead.request(produce: { Self.readMaximumCapacity() }) { [weak self] value in
            if let value { self?.cachedMaxCapacity = value }
        }
    }

    /// The integer percent from `system_profiler`'s "Maximum Capacity: NN%" line, or nil on failure.
    /// Reuses DeviceTool.run for its timeout + concurrent pipe draining (system_profiler is fast,
    /// ~0.2 s, but this keeps a wedged process from ever hanging the health queue).
    private static func readMaximumCapacity() -> Int? {
        guard let data = DeviceTool.run("/usr/sbin/system_profiler", ["SPPowerDataType"]),
              let out = String(data: data, encoding: .utf8) else { return nil }
        for line in out.split(separator: "\n") where line.contains("Maximum Capacity") {
            let digits = String(line.filter(\.isNumber))
            if let n = Int(digits), n > 0, n <= 100 { return n }
        }
        return nil
    }
}
