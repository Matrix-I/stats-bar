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

        let snapshot = i
        DispatchQueue.main.async { self.info = snapshot }
    }
}
