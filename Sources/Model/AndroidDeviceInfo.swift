// AndroidDeviceInfo.swift — Android-over-USB battery model. Populated by AndroidDeviceReader
// (adb). Android exposes far less over USB than libimobiledevice does for iOS: `dumpsys battery`
// covers only the live basics (charge %, voltage, temperature, health), while design/full-charge
// capacity come from `dumpsys batterystats` and cycle count is a best-effort read (dumpsys keys +
// sysfs fallback). Any field a given device/OEM doesn't expose stays nil and its row stays hidden.

import Foundation

struct AndroidDeviceInfo: Identifiable {
    let id: String                // adb serial
    var name = ""
    var manufacturer = ""
    var androidVersion = ""
    var levelPercent: Int?
    // Remaining charge in mAh, from `dumpsys battery`'s "Charge counter" (BATTERY_PROPERTY_CHARGE_COUNTER,
    // reported in µAh). Paired with maxCapacity for the "x / y mAh" subline under the charge bar. It's the
    // raw fuel-gauge reading, so — like the Mac card's mAh subline — it may not line up exactly with the
    // calibrated level %.
    var currentCapacity: Int?
    var voltageV: Double?
    var temperatureC: Double?
    var technology = ""
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    var healthText: String?
    // From `dumpsys batterystats` (not the fast per-second `dumpsys battery`): Android's own
    // coulomb-counter-learned full-charge estimate and the OEM-declared rated/design capacity.
    // Fetched once per connection and cached — see AndroidDeviceReader.readCapacity.
    var maxCapacity: Int?          // mAh — "Estimated battery capacity" (health-adjusted)
    var designCapacity: Int?       // mAh — "Capacity:" under "Estimated power use" (rated by OEM)
    // Android has no exposed instantaneous current (no `current_now` without root, no health HAL
    // debug dump, and "Charge counter" barely changes between 1s polls) — so unlike iOS/Mac's
    // "Charging with" (live V×I), this is the charger/port's negotiated ceiling, not a live reading.
    var maxChargingWatts: Double?
    // Best-effort. Android exposes battery cycle count inconsistently: some Android 14+ OEM builds
    // print it in `dumpsys battery` (under varying key spellings), and some kernels expose the gas
    // gauge's `cycle_count` in sysfs — but many devices (e.g. Xiaomi/HyperOS, where it sits behind a
    // non-dumpable health HAL) expose nothing without root. AndroidDeviceReader tries the dumpsys keys
    // then the sysfs fallback; when neither yields a value this stays nil and the row stays hidden.
    var cycleCount: Int?
    var serial = ""
    var errorMessage: String?
    var isStale = false
    var capturedAt: Date?

    /// Whether the menu-bar glyph should show the charging bolt. `isCharging` alone goes
    /// false the moment the phone reaches 100% even though it's still on the cable and
    /// drawing power, which left the bolt off while plugged in and full. Being externally
    /// connected is the right signal — same fix as the Mac's `BatteryInfo.isPluggedIn`.
    var isPluggedIn: Bool { externalConnected || isCharging }

    /// "Maximum Capacity" — Android's learned full-charge estimate ("Estimated battery capacity"
    /// from batterystats) against the OEM design rating. Stock Android exposes no battery-health
    /// percentage of its own, so this design ratio is the best available; it is the same figure the
    /// row previously labelled "Health (vs design)". (Distinct from `healthText`, the dumpsys
    /// battery-health *state* — Good/Overheat/etc. — still shown separately.)
    var maximumCapacityPercent: Double? {
        guard let max = maxCapacity, max > 0, let design = designCapacity, design > 0 else { return nil }
        return Double(max) / Double(design) * 100
    }
}
