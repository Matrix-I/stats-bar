// AccessoryBatteryJoin.swift — matching the battery percentages macOS publishes for Bluetooth
// accessories onto the device rows the Bluetooth popover already shows. Both sides are plain values,
// so none of this needs a radio.
//
// It exists because the obvious version — a [name: percent] dictionary, looked up per row — is what
// the GATT overlay does today, and that shape has two defects a test can pin and an eye cannot:
//
//  1. A dictionary keyed by name is a TOTAL relation. Two accessories with the same name collapse
//     onto one key, and then BOTH rows print that one number as though each had been measured. A
//     wrong percentage that looks measured is worse than no percentage at all, which is why the join
//     below claims each accessory at most once and leaves the loser empty.
//  2. macOS publishes a multi-part accessory (earbuds) as SEVERAL records that differ only in
//     `Part Identifier`, so "one record per device" is not true and a lookup keyed by name silently
//     keeps whichever record happened to come last. They are folded into one AccessoryLevels here.
//
// The name is also not a reliable key on its own: the accessory channel carries no BD_ADDR — its
// `Accessory Identifier` is a UUID unrelated to the address system_profiler prints — so identity has
// to be reconstructed. Vendor + product ID is the stronger evidence and is tried first; the name is
// the fallback, because some devices report no IDs at all on the system_profiler side (a keyboard on
// this machine reports none, and matches on its name alone, trailing space and all).

import Foundation

/// One battery reading as macOS publishes it for an accessory: a percentage, whichever part of the
/// device it belongs to, and whatever identity the record carries.
struct AccessoryBattery: Equatable {

    /// Which cell of the accessory this reading describes. A single-battery device (a mouse, a
    /// headset) reports one `.single` record; earbuds report a record per part.
    enum Part: Equatable { case single, left, right, caseUnit }

    var name: String
    var vendorID: Int?
    var productID: Int?
    var part: Part = .single
    var percent: Int

    /// A percentage from the raw capacity pair, or nil when the record can't support one.
    ///
    /// Accessories report `Max Capacity` as 100, so this is usually the identity — but the same two
    /// keys carry mAh for the Mac's own battery, and taking `Current Capacity` at face value would
    /// print a milliamp-hour count as a percent the day macOS publishes an accessory that way. The
    /// ratio is right in both worlds. Rounded rather than truncated, so a reading of 99.6 does not
    /// display as 99.
    static func percent(current: Int, maxCapacity: Int) -> Int? {
        guard current >= 0, maxCapacity > 0 else { return nil }
        let pct = Int((Double(current) / Double(maxCapacity) * 100).rounded())
        return min(100, max(0, pct))
    }

    /// The `Part Identifier` string, mapped. The key is ABSENT entirely on the records macOS
    /// publishes for BLE accessories and reads "Single" on the classic ones, so both of those — and
    /// anything unrecognised — fold into `.single`: a device with one battery is the common case, and
    /// a reading dropped for want of a label would be worse than one shown as the main level.
    static func part(_ raw: String?) -> Part {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "left":  return .left
        case "right": return .right
        case "case":  return .caseUnit
        default:      return .single
        }
    }
}

/// The battery levels attributable to one device, in the shape the Bluetooth model already uses.
struct AccessoryLevels: Equatable {
    var main: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    var isEmpty: Bool { main == nil && left == nil && right == nil && caseLevel == nil }
}

/// What the join knows about a connected device — enough to recognise it, and nothing else, so the
/// matching can be tested without a BluetoothDeviceInfo (which lives a layer up in Sources/Model).
struct DeviceIdentity: Equatable {
    var name: String
    var vendorID: Int?
    var productID: Int?

    init(name: String, vendorID: Int? = nil, productID: Int? = nil) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
    }
}

enum AccessoryBatteryJoin {

    /// Levels for each device, positionally — `result[i]` belongs to `devices[i]`, and is empty when
    /// nothing could be attributed to it.
    ///
    /// Every accessory is claimed by at most one device. Vendor + product runs as a complete pass
    /// before any name is considered, so a device that can be identified positively is never beaten
    /// to its own record by an earlier device that merely shares a name with it.
    static func levels(devices: [DeviceIdentity], accessories: [AccessoryBattery]) -> [AccessoryLevels] {
        var groups = grouped(accessories)
        var out = [AccessoryLevels](repeating: AccessoryLevels(), count: devices.count)
        // Tracked separately from `out[i].isEmpty`: a device matched to a group that turned out to
        // carry nothing must not fall through to the name pass and claim a second group.
        var matched = [Bool](repeating: false, count: devices.count)

        for (i, device) in devices.enumerated() {
            guard let vendor = device.vendorID, let product = device.productID else { continue }
            guard let g = groups.indices.first(where: {
                !groups[$0].claimed && groups[$0].vendorID == vendor && groups[$0].productID == product
            }) else { continue }
            groups[g].claimed = true
            matched[i] = true
            out[i] = groups[g].levels
        }

        for (i, device) in devices.enumerated() where !matched[i] {
            let key = normalized(device.name)
            guard !key.isEmpty else { continue }
            guard let g = groups.indices.first(where: { !groups[$0].claimed && groups[$0].name == key })
            else { continue }
            groups[g].claimed = true
            matched[i] = true
            out[i] = groups[g].levels
        }

        return out
    }

    /// Trailing space and case are not identity: system_profiler and the accessory channel both
    /// report one keyboard on this machine as `"R65 5.0 "`, and neither is the authority on how the
    /// other spells it.
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// One logical accessory: the records that share a name and an ID pair, folded into one set of
    /// levels. Source order is preserved so that identical devices pair off with identical rows in
    /// the order both lists report them, rather than by whichever hashes first.
    private struct Group {
        var name: String
        var vendorID: Int?
        var productID: Int?
        var levels = AccessoryLevels()
        var claimed = false

        /// Whether this accessory already has a reading for that part — which is what tells two
        /// devices apart when nothing else does. See `grouped`.
        func holds(_ part: AccessoryBattery.Part) -> Bool {
            switch part {
            case .single:   return levels.main != nil
            case .left:     return levels.left != nil
            case .right:    return levels.right != nil
            case .caseUnit: return levels.caseLevel != nil
            }
        }

        mutating func add(_ reading: AccessoryBattery) {
            switch reading.part {
            case .single:   levels.main = reading.percent
            case .left:     levels.left = reading.percent
            case .right:    levels.right = reading.percent
            case .caseUnit: levels.caseLevel = reading.percent
            }
        }
    }

    /// Records collected into one entry per physical accessory.
    ///
    /// Identity alone is not enough to group by, and the difference matters in both directions: the
    /// records of ONE pair of earbuds share a name and an ID pair and must fold together, while TWO
    /// identical mice also share a name and an ID pair and must not. What separates them is the part
    /// — an accessory has one left bud, so a second record claiming a slot that is already filled is
    /// a second device rather than a contradiction, and starts a new group.
    ///
    /// (The records do carry an `Accessory Identifier` UUID that would answer this directly, but
    /// whether the parts of one multi-part accessory share it has not been verified on hardware —
    /// there were no earbuds connected — and grouping on an unverified assumption would split a pair
    /// of AirPods into three rows that each claim one bud. This rule needs no such assumption.)
    private static func grouped(_ accessories: [AccessoryBattery]) -> [Group] {
        var groups: [Group] = []
        for reading in accessories {
            let key = normalized(reading.name)
            if let i = groups.firstIndex(where: {
                $0.name == key && $0.vendorID == reading.vendorID
                    && $0.productID == reading.productID && !$0.holds(reading.part)
            }) {
                groups[i].add(reading)
            } else {
                var group = Group(name: key, vendorID: reading.vendorID, productID: reading.productID)
                group.add(reading)
                groups.append(group)
            }
        }
        return groups
    }
}
