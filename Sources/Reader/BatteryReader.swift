// BatteryReader.swift — reads the Mac's battery straight from the IOKit "AppleSmartBattery"
// registry (the same source coconutBattery uses — no root, no kernel extension) plus the live
// SMC power rails, and publishes a BatteryInfo on the main thread.

import Foundation
import Combine
import IOKit

final class BatteryReader: ObservableObject {
    @Published var info = BatteryInfo()
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private let smc = SMC()

    // "Maximum Capacity" (macOS's own battery-health figure — System Information / Battery Health)
    // has no public IOKit key: Apple computes it with a private, smoothed algorithm that no raw
    // ratio reproduces. So we read the exact value macOS reports from `system_profiler`, but only
    // every few minutes on a background queue — battery health drifts over weeks, never per-second,
    // so the 1 Hz gauge path below never pays that cost. These are all touched on the main thread.
    private var cachedMaxCapacity: Int?
    private var healthReadInFlight = false
    private var lastHealthRead = Date.distantPast
    private let healthQueue = DispatchQueue(label: "BatteryReader.health", qos: .utility)
    private static let healthInterval: TimeInterval = 300

    private static let idleInterval: TimeInterval = 1    // refresh every second, even for the menu-bar glyph alone
    private static let activeInterval: TimeInterval = 1  // live readout while the detail panel is open

    init() {
        refresh()
        schedule(Self.idleInterval)
    }

    private func schedule(_ seconds: TimeInterval) {
        guard seconds != interval else { return }
        interval = seconds
        timer?.invalidate()
        // Register in .common modes, not the implicit .default of scheduledTimer: while the
        // menu-bar popover is up the run loop can sit in event-tracking mode, where a
        // .default-only timer never fires — that's what makes the "live" readout freeze.
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Poll once a second while the detail panel is visible; drop back to the lazy cadence when it closes.
    func setPanelOpen(_ open: Bool) {
        schedule(open ? Self.activeInterval : Self.idleInterval)
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

        // Live SMC power rails (these actually move every second — see the header note on BatteryInfo).
        i.smcSystemTotalW  = smc.readFloat("PSTR")
        i.smcDCInW         = smc.readFloat("PDTR")
        i.smcBrightnessW   = smc.readFloat("PDBR")
        i.smcThunderboltLW = smc.readFloat("PU1R")
        i.smcThunderboltRW = smc.readFloat("PU2R")
        i.smcPPBRW         = smc.readFloat("PPBR")

        // Live fan speeds — same SMC user client, also ~1 Hz.
        i.fans = smc.readFans()

        // Live RAM + swap usage (Mach VM statistics — independent of the SMC / battery gauge).
        i.memory = MemoryStats.read()

        // macOS's own "Maximum Capacity" — refreshed at most every few minutes, off the main
        // thread (see the note on the cache fields above). Publish the last value we have.
        maybeReadMaximumCapacity()
        i.maximumCapacityPercent = cachedMaxCapacity

        let snapshot = i
        DispatchQueue.main.async { self.info = snapshot }
    }

    /// Refresh macOS's "Maximum Capacity" at most once every `healthInterval`, off the main thread.
    /// Called from `refresh()` (main); the read itself runs on `healthQueue` and hands the result
    /// back on main so the cache fields are only ever touched there.
    private func maybeReadMaximumCapacity() {
        guard !healthReadInFlight,
              Date().timeIntervalSince(lastHealthRead) >= Self.healthInterval else { return }
        healthReadInFlight = true
        healthQueue.async { [weak self] in
            let value = Self.readMaximumCapacity()
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastHealthRead = Date()
                self.healthReadInFlight = false
                if let value { self.cachedMaxCapacity = value }
            }
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
