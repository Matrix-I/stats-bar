// IOSDeviceInfo.swift — iPhone/iPad-over-USB battery model. Populated by IOSDeviceReader,
// which shells out to libimobiledevice (same approach as cocobat.py --ios).

import Foundation

struct IOSDeviceInfo: Identifiable {
    let id: String               // UDID
    var name = ""
    var model = ""
    var iosVersion = ""
    var serial = ""
    var currentCapacity: Int?     // mAh — raw coulomb count (AppleRawCurrentCapacity)
    var stateOfCharge: Double?    // % — calibrated State of Charge iOS shows (relative CurrentCapacity), not the raw mAh ratio
    var maxCapacity: Int?         // mAh — raw full-charge capacity (AppleRawMaxCapacity)
    var nominalChargeCapacity: Int?  // mAh — gauge's learned nominal capacity; basis for iOS's Maximum Capacity
    var designCapacity: Int?
    var cycleCount: Int?
    var temperatureC: Double?
    var voltageV: Double?
    var amperageA: Double?         // negative = discharging, positive = charging
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    var errorMessage: String?
    var isStale = false           // true = currently showing the last known data because the connection briefly dropped
    var isNetwork = false         // reached over Wi-Fi sync (idevice_id -n) instead of USB — the device is
                                  // plugged into some other power source (or a charge-only cable/hub that
                                  // carries no data), yet still readable over the network, so we surface it
                                  // and read it with the `-n` flag rather than dropping it.
    var isLocked = false          // device is present + trusted but at the passcode lock screen: the diagnostics
                                  // registry (mAh/health/cycle) is refused, so those values are last-known or absent
    var isLightRead = false       // internal: this row came from the cheap glyph-only pass (charge % + charging via
                                  // the battery domain, no health read). Grafted like a locked row and never a
                                  // baseline; not surfaced in the UI, since the popover always triggers a full read
    var lockedChargePercent: Double?  // live 0–100% charge from the lockdown battery domain, readable while locked
    var capturedAt: Date?         // timestamp this data was captured (for a locked row: when the health figures were last read)

    /// Whether the menu-bar glyph should show the charging bolt. `isCharging` alone goes
    /// false the moment the phone reaches 100% even though it's still on the cable and
    /// drawing power, which left the bolt off while plugged in and full. Being externally
    /// connected is the right signal — same fix as the Mac's `BatteryInfo.isPluggedIn`.
    var isPluggedIn: Bool { externalConnected || isCharging }

    var chargePercent: Double? {
        // The calibrated State of Charge iOS itself shows (0–100), read from the relative
        // CurrentCapacity key — NOT AppleRawCurrentCapacity / AppleRawMaxCapacity, which reads a
        // point or two off (same reason as the Mac's BatteryInfo.chargePercent).
        if let soc = stateOfCharge { return soc }
        if let cur = currentCapacity, let max = maxCapacity, max > 0 {
            return Double(cur) / Double(max) * 100
        }
        // Locked device: the diagnostics registry is unavailable, but the lockdown battery domain
        // still reports a coarse 0–100% charge level (also the calibrated SoC).
        return lockedChargePercent
    }
    /// iOS's own "Maximum Capacity" (Settings → Battery → Battery Health). iOS derives it from
    /// NominalChargeCapacity / DesignCapacity — the gauge's learned nominal capacity against the
    /// design rating — which reads a couple of points higher than the raw full-charge ratio
    /// (AppleRawMaxCapacity / DesignCapacity). Falls back to that raw ratio only when the nominal
    /// key is absent, so the row always shows something.
    var maximumCapacityPercent: Double? {
        guard let design = designCapacity, design > 0 else { return nil }
        if let nominal = nominalChargeCapacity, nominal > 0 {
            return Double(nominal) / Double(design) * 100
        }
        if let max = maxCapacity, max > 0 {
            return Double(max) / Double(design) * 100
        }
        return nil
    }
    /// Raw full-charge-vs-design ratio (AppleRawMaxCapacity / DesignCapacity) — the
    /// coconutBattery-style number, shown small beside Maximum Capacity for the technically
    /// inclined. nil (and hidden) when it would just duplicate the figure above.
    var rawHealthPercent: Double? {
        guard let max = maxCapacity, max > 0, let design = designCapacity, design > 0 else { return nil }
        return Double(max) / Double(design) * 100
    }
    var watts: Double? {
        guard let v = voltageV, let a = amperageA else { return nil }
        return v * a
    }
}
