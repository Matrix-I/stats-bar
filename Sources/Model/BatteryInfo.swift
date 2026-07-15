// BatteryInfo.swift — Mac battery model, populated from the IOKit "AppleSmartBattery"
// registry + live SMC power rails. See BatteryReader for how each field is filled.

import Foundation

struct BatteryInfo {
    var deviceName = "Battery"
    var serial = ""
    var currentCapacity = 0      // mAh
    var maxCapacity = 0          // mAh — actual full charge capacity
    var designCapacity = 0       // mAh — design capacity
    var cycleCount = 0
    var temperatureC = 0.0
    var voltageV = 0.0
    var amperageA = 0.0          // negative = discharging, positive = charging
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    var timeToEmpty = 0          // minutes (65535 = still calculating)
    var timeToFull = 0           // minutes
    var adapterWatts = 0
    var adapterName = ""
    var adapterPower = 0.0        // W — actual DC in power drawn from the charger (BatteryData.AdapterPower)

    // Live SMC power rails (~1 Hz — unlike the AppleSmartBattery gauge above, which only
    // refreshes every ~30–60 s). nil when the machine doesn't expose that key / SMC is unavailable.
    var smcSystemTotalW: Double? = nil   // PSTR — whole-system power
    var smcDCInW: Double? = nil          // PDTR — power drawn from the charger
    var smcBrightnessW: Double? = nil    // PDBR — display backlight
    var smcThunderboltLW: Double? = nil  // PU1R
    var smcThunderboltRW: Double? = nil  // PU2R
    var smcPPBRW: Double? = nil          // PPBR

    // Live fan speeds in RPM (SMC F<n>Ac keys, ~1 Hz). Empty on fanless Macs (e.g. MacBook Air) or
    // when SMC is unavailable.
    var fans: [Double] = []

    // Live physical-RAM + swap usage (~1 Hz, from the Mach VM statistics — see MemoryStats).
    // nil only if the VM stats read fails, which is effectively never on a real Mac.
    var memory: MemoryInfo? = nil

    /// Whether the menu-bar glyph should show the charging bolt. `isCharging` alone drops
    /// to false the instant the battery reaches 100% (or while it's held at a charge limit
    /// by battery-health management) even though the charger is still connected and DC power
    /// is flowing in — which left the bolt off while plugged in and full. Being on external
    /// charger power is the right signal; macOS keeps its own menu-bar bolt lit the same way.
    var isPluggedIn: Bool { externalConnected || isCharging }

    var chargePercent: Double {
        maxCapacity > 0 ? Double(currentCapacity) / Double(maxCapacity) * 100 : 0
    }
    var healthPercent: Double {
        designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) * 100 : 0
    }
    var watts: Double { voltageV * amperageA }
}
