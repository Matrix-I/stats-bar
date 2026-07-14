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

    var chargePercent: Double {
        maxCapacity > 0 ? Double(currentCapacity) / Double(maxCapacity) * 100 : 0
    }
    var healthPercent: Double {
        designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) * 100 : 0
    }
    var watts: Double { voltageV * amperageA }
}
