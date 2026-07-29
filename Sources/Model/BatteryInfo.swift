// BatteryInfo.swift — Mac battery model, populated from the IOKit "AppleSmartBattery"
// registry + live SMC power rails. See BatteryReader for how each field is filled.

import Foundation

/// One fan's live state as the SMC reports it, in RPM. `minimum`/`maximum` are that fan's fixed
/// limits and `target` the speed the controller is currently aiming for — the three numbers that
/// turn a bare "2334 rpm" into something you can judge, and that let the panel show a fan ramping
/// up before it becomes audible. Any field this machine doesn't publish stays nil.
struct FanInfo: Identifiable {
    let index: Int
    let actual: Double
    let minimum: Double?
    let maximum: Double?
    let target: Double?
    var id: Int { index }

    /// Where the current speed sits between this fan's own limits (0…1), or nil when the machine
    /// doesn't publish both ends. Percent-of-range is far more legible than the raw RPM, whose
    /// meaning differs per fan — on this M1 Pro fan 0 tops out at 5779 rpm and fan 1 at 6241.
    var rangeFraction: Double? {
        guard let lo = minimum, let hi = maximum, hi > lo else { return nil }
        return min(1, max(0, (actual - lo) / (hi - lo)))
    }

    /// True when the controller is asking for a materially different speed than the fan is doing —
    /// i.e. it is spinning up or down right now. The 50 rpm dead-band keeps normal servo jitter from
    /// flagging every reading.
    var isRamping: Bool {
        guard let t = target else { return false }
        return abs(t - actual) > 50
    }
}

struct BatteryInfo {
    var deviceName = "Battery"
    var serial = ""
    var currentCapacity = 0      // mAh — raw coulomb count (AppleRawCurrentCapacity)
    var maxCapacity = 0          // mAh — actual full charge capacity
    var designCapacity = 0       // mAh — design capacity
    var stateOfCharge = 0.0      // % — calibrated State of Charge macOS shows (0–100), not the raw mAh ratio
    var maximumCapacityPercent: Int? = nil  // % — macOS's own "Maximum Capacity" (System Information / Battery Health); nil until first read
    var cycleCount = 0
    var designCycleCount = 0     // rated cycle life (DesignCycleCount9C); 0 when the pack omits it
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

    // Live fan state (SMC F<n>* keys, ~1 Hz). Empty on fanless Macs (e.g. MacBook Air) or when SMC
    // is unavailable.
    var fans: [FanInfo] = []

    /// Whether the menu-bar glyph should show the charging bolt. `isCharging` alone drops
    /// to false the instant the battery reaches 100% (or while it's held at a charge limit
    /// by battery-health management) even though the charger is still connected and DC power
    /// is flowing in — which left the bolt off while plugged in and full. Being on external
    /// charger power is the right signal; macOS keeps its own menu-bar bolt lit the same way.
    var isPluggedIn: Bool { externalConnected || isCharging }

    /// The percentage shown in the menu bar and detail panel. This is the calibrated State of
    /// Charge (what macOS's System Information reports and what reaches 100 % at full), NOT the
    /// raw mAh ratio AppleRawCurrentCapacity / AppleRawMaxCapacity — that raw ratio reads a few
    /// percent low even when the battery is full, because battery-health management holds the
    /// pack just under its learned full-charge capacity. See BatteryReader for how it's read.
    var chargePercent: Double { stateOfCharge }
    var healthPercent: Double {
        designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) * 100 : 0
    }
    /// Percentage to show for "Maximum Capacity" — macOS's own figure once we've read it (see
    /// BatteryReader), falling back to the raw full-charge-vs-design fraction only until the
    /// first read lands. macOS's figure comes from a private, smoothed algorithm no public IOKit
    /// key reproduces, so the raw ratio here reads a few points lower than what macOS reports.
    var displayMaximumCapacity: Double {
        maximumCapacityPercent.map(Double.init) ?? healthPercent
    }
    var watts: Double { voltageV * amperageA }

    /// Share of the pack's rated cycle life already used (0…1), or nil when no rating is published.
    /// A bare cycle count means nothing without it — 307 is a third of the way through a 1000-cycle
    /// pack, which is the sentence the number is trying to say.
    var cycleLifeFraction: Double? {
        guard designCycleCount > 0 else { return nil }
        return min(1, Double(cycleCount) / Double(designCycleCount))
    }
}
