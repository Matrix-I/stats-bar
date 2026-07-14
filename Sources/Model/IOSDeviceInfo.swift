// IOSDeviceInfo.swift — iPhone/iPad-over-USB battery model. Populated by IOSDeviceReader,
// which shells out to libimobiledevice (same approach as cocobat.py --ios).

import Foundation

struct IOSDeviceInfo: Identifiable {
    let id: String               // UDID
    var name = ""
    var model = ""
    var iosVersion = ""
    var serial = ""
    var currentCapacity: Int?     // mAh — nil if diagnostics doesn't return this key
    var maxCapacity: Int?
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
    var capturedAt: Date?         // timestamp this data was captured

    var chargePercent: Double? {
        guard let cur = currentCapacity, let max = maxCapacity, max > 0 else { return nil }
        return Double(cur) / Double(max) * 100
    }
    var healthPercent: Double? {
        guard let max = maxCapacity, max > 0, let design = designCapacity, design > 0 else { return nil }
        return Double(max) / Double(design) * 100
    }
    var watts: Double? {
        guard let v = voltageV, let a = amperageA else { return nil }
        return v * a
    }
}
