// SmartBatteryRegistry.swift — which keys of an AppleSmartBattery entry hold which figure.
// A dictionary in, the battery numbers out; no I/O, so the mapping can be pinned.
//
// One type for both cards. The Mac reads this entry from its own IOKit and an iPhone's arrives over
// lockdown, but it is the same driver publishing the same dictionary — and, the reason this is shared
// rather than copied, Apple moved the same keys the same way on both in the same autumn. It was
// written for iOS 27 first; macOS 27 turned out to have done it too, and the parser needed no change
// at all to read a Mac correctly, only to be called by the Mac's reader.
//
// Up to iOS 26 / macOS 26 the gauge published mAh at the top level of the registry, under the names
// coconutBattery and cocobat.py read — AppleRawCurrentCapacity, AppleRawMaxCapacity,
// NominalChargeCapacity, DesignCapacity — and both readers asked for exactly those. Measured on an
// iPhone 17 (iPhone17,3, iOS 27.0) and a MacBook Pro (J314s, macOS 27), they are gone from the top
// level and the same figures sit inside a BatteryData sub-dictionary under partly different names:
//
//   BatteryData/DesignCapacity          was DesignCapacity
//   BatteryData/FullChargeCapacity      was AppleRawMaxCapacity
//   BatteryData/NominalChargeCapacity   was NominalChargeCapacity
//   BatteryData/RemainingCapacity       was AppleRawCurrentCapacity
//
// CycleCount, Voltage and Amperage stayed at the top level on both, which is why each card went on
// showing three live, correct numbers while its capacities quietly stopped existing — a panel that
// reads as merely sparse rather than broken, with no error anywhere.
//
// THE TRAP, and the reason this is a file with tests rather than four `??` in a reader: the top level
// still carries CurrentCapacity and MaxCapacity, and on both systems those are PERCENTAGES — 65 and
// 100 on the measured iPhone, beside a battery of 3521 mAh; 100 and 100 on the Mac, beside 6075 mAh.
// They are the obvious names to reach for once the mAh keys are missing, they are Ints like the keys
// they would replace, and nothing downstream can tell the difference: a card printing "65 mAh of 100
// mAh" and a battery health of 3% is formatted exactly like a real reading.
//
// On the Mac that was not hypothetical, it had already happened. Its reader carried
// `if maxCapacity == 0 { maxCapacity = intOf(props["MaxCapacity"]) }` for old Intel machines, where
// those keys genuinely did hold mAh — a fallback that had been correct for years and that macOS 27
// walked straight into. The card showed "Full charge capacity: 100 mAh" above "Design capacity: 0
// mAh". So the two units are kept apart here by construction: the mAh fields only ever read mAh keys,
// and the percentage pair only ever feeds stateOfCharge.
//
// Temperature did not go away; it went next door, and finding it took two sweeps. On both systems
// the gauge has an entry of its own, AppleSmartBatteryPack, beside AppleSmartBattery in the IOService
// plane, and its BatteryData carries the vocabulary the top level lost — Temperature, VirtualTemperature,
// AppleRawMaxCapacity, AppleRawCurrentCapacity, DesignCapacity, CycleCount, Serial — under the OLD
// names. Centi-degrees as before: 2979 on the charging iPhone, 3100 on the Mac. The percentage pair
// is in there too (CurrentCapacity 75 / MaxCapacity 100 on the phone), so the pack is a third place
// the trap above lives, and `parse` reads the pack's mAh from its AppleRaw* keys only.
//
// The first sweep for a replacement concluded there was none, and why it was wrong is worth keeping:
// it indexed the IOPower plane to choose which entries to read, and IOPower lists only power-managed
// nodes. The pack is not one. The IOService plane, three times the size, is where it appears — 873
// identities IOPower does not have — so a future search for a moved key starts there. What that first
// sweep did establish still holds: `diagnostics GasGauge` yields a FullChargeCapacity that is a
// percentage (the trap again, under a fourth name), `mobilegestalt` is deprecated wholesale, and
// nothing in the AppleSmartBattery entry itself — 332 leaves — is a temperature.
//
// So `parse` takes the pack as a second dictionary, consulted only for what the entry lacks, and
// `wantsPack` tells a reader when fetching it is worth a call: on an iPhone that is one more
// subprocess per read, and a device still on the old layout must never pay it. The Mac keeps one tier
// below the pack — its own SMC still publishes the pack sensors TB0T/TB1T/TB2T — for a machine that
// publishes neither key; that lives in BatteryReader, not here.

import Foundation

/// The battery figures an AppleSmartBattery registry entry can yield, in the units the model wants.
struct SmartBatteryRegistry: Equatable {
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

    /// Reads both layouts: iOS 26's top-level keys first, then iOS 27's BatteryData, then — when the
    /// reader fetched it — the AppleSmartBatteryPack entry's BatteryData under the old names. Each field
    /// falls back on its own rather than the whole struct switching layout, because a release that
    /// moves some keys and not others is precisely what happened here — CycleCount, Voltage and
    /// Amperage stayed put while the capacities moved — and a layout picked once, from one key, would
    /// then be wrong for the rest.
    static func parse(_ reg: [String: Any], pack: [String: Any]? = nil) -> SmartBatteryRegistry {
        let batteryData = reg["BatteryData"] as? [String: Any] ?? [:]
        let packData = pack?["BatteryData"] as? [String: Any] ?? [:]
        /// Top level first, then the same question of the entry's BatteryData under its new name, then
        /// of the pack's BatteryData under the old one — the pack kept the vocabulary the top level lost.
        func mAh(_ topLevel: String, _ nested: String) -> Int? {
            int(reg[topLevel]) ?? int(batteryData[nested]) ?? int(packData[topLevel])
        }

        var out = SmartBatteryRegistry()
        out.serial = reg["Serial"] as? String ?? pack?["Serial"] as? String
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

        out.cycleCount = int(reg["CycleCount"]) ?? int(packData["CycleCount"])
        // Signed for the same reason as Amperage below — see BatteryReader. Reading a sub-zero
        // temperature unsigned would also trip TemperatureAlerter's hot-battery warning, since the
        // bogus value is far above the threshold. The pack is where iOS 27 and macOS 27 keep this.
        if let t = signed(reg["Temperature"]) ?? signed(packData["Temperature"]) { out.temperatureC = Double(t) / 100.0 }
        if let v = int(reg["Voltage"]) ?? int(packData["Voltage"]) { out.voltageV = Double(v) / 1000.0 }
        if let a = signed(reg["Amperage"]) ?? signed(packData["Amperage"]) { out.amperageA = Double(a) / 1000.0 }
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

    /// Whether the AppleSmartBattery entry is missing something the AppleSmartBatteryPack entry has,
    /// so that fetching the pack is worth its cost. On an iPhone that cost is a second subprocess per
    /// read, so this is deliberately keyed on the two things only the pack can now supply rather than
    /// on "is this iOS 27": a device still publishing Temperature and AppleRawMaxCapacity at the top
    /// level reads exactly as it did, with exactly the calls it made.
    static func wantsPack(_ reg: [String: Any]) -> Bool {
        reg["Temperature"] == nil || reg["AppleRawMaxCapacity"] == nil
    }

    // `int` is a local copy of IOKitValues' helper, which lives in Sources/Support and so is not
    // compiled into the test target; `signed` is now the only copy, the Support twin having gone
    // unused once both readers' battery parsing moved here. Private and namespaced rather than free
    // functions, because the app builds every directory as one module and a second top-level
    // `intOrNil` would not compile.
    private static func int(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }

    /// IOKit sometimes returns negative numbers as unsigned 32-bit (e.g. Amperage while discharging).
    private static func signed(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber else { return nil }
        var v = n.int64Value
        if v > 0x7FFF_FFFF && v <= 0xFFFF_FFFF { v -= 0x1_0000_0000 }
        return Int(v)
    }
}
