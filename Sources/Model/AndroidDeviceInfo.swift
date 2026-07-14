// AndroidDeviceInfo.swift — Android-over-USB battery model. Populated by AndroidDeviceReader
// (adb). Android exposes far less over USB than libimobiledevice does for iOS: `dumpsys battery`
// has no cycle count or design/full-charge capacity on stock Android, so those fields simply
// don't exist here — the UI only shows what's actually available (charge %, voltage, temperature,
// health).

import Foundation

struct AndroidDeviceInfo: Identifiable {
    let id: String                // adb serial
    var name = ""
    var manufacturer = ""
    var androidVersion = ""
    var levelPercent: Int?
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
    // Confirmed unavailable on Android 9–13 (checked getprop, dumpsys battery/batterystats, and
    // sysfs — nothing exposes it). Android only added a public cycle-count property in Android 14,
    // and only if the OEM's health HAL reports it, so this is a best-effort, unverified parse of a
    // hypothetical "Charge cycles" line — harmless if the key doesn't exist (stays nil, row stays hidden).
    var cycleCount: Int?
    var serial = ""
    var errorMessage: String?
    var isStale = false
    var capturedAt: Date?

    var healthPercent: Double? {
        guard let max = maxCapacity, max > 0, let design = designCapacity, design > 0 else { return nil }
        return Double(max) / Double(design) * 100
    }
}
