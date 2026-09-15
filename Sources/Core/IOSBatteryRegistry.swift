// IOSBatteryRegistry.swift — which keys of an iPhone's AppleSmartBattery entry hold which figure.
// A dictionary in, the battery numbers out; no I/O, so the mapping can be pinned.
//
// iOS moved them. Up to iOS 26 the gauge published mAh at the top level of the registry, under the
// names coconutBattery and cocobat.py read — AppleRawCurrentCapacity, AppleRawMaxCapacity,
// NominalChargeCapacity, DesignCapacity — and the reader asked for exactly those. On iOS 27 (measured
// on an iPhone 17, iPhone17,3) all four are gone from the top level and the same figures appear inside
// a BatteryData sub-dictionary under partly different names:
//
//   BatteryData/DesignCapacity          3521   was DesignCapacity
//   BatteryData/FullChargeCapacity      3545   was AppleRawMaxCapacity
//   BatteryData/NominalChargeCapacity   3519   was NominalChargeCapacity
//   BatteryData/RemainingCapacity       2281   was AppleRawCurrentCapacity
//
// CycleCount, Voltage and Amperage stayed at the top level, which is why the card kept showing three
// live numbers while Maximum Capacity and every mAh figure silently vanished — a panel that looks
// merely sparse rather than broken.
//
// THE TRAP, and the reason this is a file with tests rather than four `??` in the reader: the top
// level still carries CurrentCapacity and MaxCapacity, and on iOS 27 those are PERCENTAGES — 65 and
// 100 on the device above, beside a battery of 3521 mAh. They are the obvious names to reach for once
// the mAh keys are missing, they are Ints like the keys they would replace, and nothing downstream
// can tell the difference: the card would print "65 mAh of 100 mAh" and a battery health of 100/3521
// = 3%, all of it formatted exactly like a real reading. So the two units are kept apart here by
// construction — the mAh fields only ever read mAh keys, and the percentage pair only ever feeds
// stateOfCharge.
//
// Temperature has no replacement. It is absent from the top level and from every sub-dictionary on
// iOS 27; the only battery temperatures left in the entry are an IOReportLegend listing channel names
// (BatteryAvgTemp, BatteryMaxTemp) with no values attached, and a DeadBatteryBootData payload that
// reads zero. So temperatureC comes back nil there, the row hides itself, and TemperatureAlerter
// stays quiet rather than warning on a fabricated figure.

import Foundation

/// The battery figures an AppleSmartBattery registry entry can yield, in the units the model wants.
struct IOSBatteryRegistry: Equatable {
    var serial: String?
    /// mAh, all four — never the percentage pair. See the header.
    var designCapacity: Int?
    var maxCapacity: Int?
    var nominalChargeCapacity: Int?
    var currentCapacity: Int?
    /// Percent, 0–100: the calibrated charge iOS itself shows.
    var stateOfCharge: Double?
    var cycleCount: Int?
    var temperatureC: Double?
    var voltageV: Double?
    var amperageA: Double?
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false

    /// Reads both layouts: iOS 26's top-level keys first, then iOS 27's BatteryData. Each field falls
    /// back on its own rather than the whole struct switching layout, because a release that moves
    /// some keys and not others is precisely what happened here — CycleCount, Voltage and Amperage
    /// stayed put while the capacities moved — and a layout picked once, from one key, would then be
    /// wrong for the rest.
    static func parse(_ reg: [String: Any]) -> IOSBatteryRegistry {
        let batteryData = reg["BatteryData"] as? [String: Any] ?? [:]
        /// Top level first, then the same question of BatteryData.
        func mAh(_ topLevel: String, _ nested: String) -> Int? {
            int(reg[topLevel]) ?? int(batteryData[nested])
        }

        var out = IOSBatteryRegistry()
        out.serial = reg["Serial"] as? String
        out.designCapacity = mAh("DesignCapacity", "DesignCapacity")
        // Full-charge capacity, falling back to the nominal figure as it always has: the raw key is
        // what the caption under Maximum Capacity divides, and without it the card would show the
        // headline alone rather than nothing.
        out.maxCapacity = mAh("AppleRawMaxCapacity", "FullChargeCapacity")
            ?? mAh("NominalChargeCapacity", "NominalChargeCapacity")
        out.nominalChargeCapacity = mAh("NominalChargeCapacity", "NominalChargeCapacity")
        // RemainingCapacity rather than AbsoluteCapacity (2281 against 2342 on the measured device):
        // it is the figure that shares a denominator with FullChargeCapacity, so the raw ratio it
        // forms lands a fraction under the calibrated state of charge the way AppleRawCurrentCapacity
        // always did, instead of a couple of points over it.
        out.currentCapacity = mAh("AppleRawCurrentCapacity", "RemainingCapacity")

        // The percentage pair, kept to the one field that wants a percentage. Present at the top
        // level on both layouts; BatteryData carries a copy, read only if the top level ever loses it.
        if let relMax = int(reg["MaxCapacity"]) ?? int(batteryData["MaxCapacity"]), relMax > 0,
           let relCur = int(reg["CurrentCapacity"]) ?? int(batteryData["CurrentCapacity"]) {
            out.stateOfCharge = min(100, Double(relCur) / Double(relMax) * 100)
        }

        out.cycleCount = int(reg["CycleCount"])
        // Signed for the same reason as Amperage below — see BatteryReader. Reading a sub-zero
        // temperature unsigned would also trip TemperatureAlerter's hot-battery warning, since the
        // bogus value is far above the threshold.
        if let t = signed(reg["Temperature"]) { out.temperatureC = Double(t) / 100.0 }
        if let v = int(reg["Voltage"]) { out.voltageV = Double(v) / 1000.0 }
        if let a = signed(reg["Amperage"]) { out.amperageA = Double(a) / 1000.0 }
        out.isCharging = reg["IsCharging"] as? Bool ?? (int(batteryData["IsCharging"]).map { $0 != 0 } ?? false)
        out.externalConnected = reg["ExternalConnected"] as? Bool ?? false
        out.fullyCharged = reg["FullyCharged"] as? Bool ?? (int(batteryData["FullyCharged"]).map { $0 != 0 } ?? false)
        return out
    }

    /// Whether a registry entry looks like a battery at all. The reader retries the probe until this
    /// holds, so it is the difference between "the device answered" and "the device is locked".
    ///
    /// BatteryData is listed because on iOS 27 the other four are down to CycleCount alone, and a
    /// single key surviving is not a condition to rest a retry loop on — the whole point of this file
    /// is that Apple moves these.
    static func looksLikeABattery(_ reg: [String: Any]) -> Bool {
        reg["BatteryData"] != nil || reg["AppleRawMaxCapacity"] != nil || reg["NominalChargeCapacity"] != nil
            || reg["DesignCapacity"] != nil || reg["CycleCount"] != nil
    }

    // Local copies of the IOKitValues helpers, which live in Sources/Support and so are not compiled
    // into the test target. Private and namespaced rather than free functions, because the app builds
    // every directory as one module and a second top-level `intOrNil` would not compile.
    private static func int(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }

    /// IOKit sometimes returns negative numbers as unsigned 32-bit (e.g. Amperage while discharging).
    private static func signed(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber else { return nil }
        var v = n.int64Value
        if v > 0x7FFF_FFFF && v <= 0xFFFF_FFFF { v -= 0x1_0000_0000 }
        return Int(v)
    }
}
