// IOSBatteryRegistryTests.swift — the key names an iPhone's battery figures arrive under.
//
// The failure this guards is not a crash and not an empty card. It is a card that keeps rendering
// perfectly while four of its numbers quietly stop existing, which is exactly what iOS 27 did: the
// mAh keys moved into a BatteryData sub-dictionary, the reader went on asking for them at the top
// level, and the panel lost Maximum Capacity and every capacity row without anything going red.
//
// Both fixtures below are real. The iOS 27 one is captured verbatim from an iPhone 17 (iPhone17,3,
// iOS 27.0) over USB while charging; the iOS 26 one is the shape the reader was written against and
// read against shipping devices for the life of this feature.

import Testing
@testable import StatsBarCore

@Suite("iOS battery registry")
struct IOSBatteryRegistryTests {

    /// iPhone 17 on iOS 27.0, charging, captured with `idevicediagnostics ioregentry AppleSmartBattery`.
    /// Trimmed to the keys this type reads plus the two that make the trap reachable.
    static let ios27: [String: Any] = [
        "Serial": "FQ1HJM00D8Z0000NPM",
        "CycleCount": 106,
        "Voltage": 4208,
        "Amperage": 2310,
        "IsCharging": true,
        "ExternalConnected": true,
        "FullyCharged": false,
        // Percentages, at the top level, next to a 3521 mAh battery. See the header of the type.
        "CurrentCapacity": 65,
        "MaxCapacity": 100,
        "BatteryData": [
            "AbsoluteCapacity": 2342,
            "CurrentCapacity": 65,
            "DesignCapacity": 3521,
            "FullChargeCapacity": 3545,
            "MaxCapacity": 100,
            "NominalChargeCapacity": 3519,
            "RemainingCapacity": 2281,
            "TrueRemainingCapacity": 2280,
        ],
    ]

    /// The layout every iPhone published up to iOS 26, and the one the reader asked for.
    static let ios26: [String: Any] = [
        "Serial": "F17ABC000000",
        "CycleCount": 312,
        "Voltage": 3950,
        "Amperage": -450,
        "Temperature": 2934,
        "IsCharging": false,
        "ExternalConnected": false,
        "FullyCharged": false,
        "CurrentCapacity": 58,
        "MaxCapacity": 100,
        "DesignCapacity": 3279,
        "AppleRawMaxCapacity": 3054,
        "NominalChargeCapacity": 3061,
        "AppleRawCurrentCapacity": 1772,
    ]

    // MARK: The regression that started this

    @Test("iOS 27's capacities are found inside BatteryData")
    func ios27CapacitiesAreRead() {
        let b = IOSBatteryRegistry.parse(Self.ios27)
        #expect(b.designCapacity == 3521)
        #expect(b.maxCapacity == 3545)             // BatteryData/FullChargeCapacity
        #expect(b.nominalChargeCapacity == 3519)
        #expect(b.currentCapacity == 2281)         // BatteryData/RemainingCapacity
    }

    @Test("the percentage pair never reaches a milliamp-hour field")
    func percentagesAreNotMilliampHours() {
        // The whole reason this file exists. On iOS 27 the top level still has CurrentCapacity 65 and
        // MaxCapacity 100 — Ints, plausible, and the obvious names to fall back to once the mAh keys
        // are missing. Taking them would print "65 mAh" beside a 3521 mAh design capacity and a
        // battery health of 3%, formatted exactly like a real reading.
        let b = IOSBatteryRegistry.parse(Self.ios27)
        for mAh in [b.designCapacity, b.maxCapacity, b.nominalChargeCapacity, b.currentCapacity] {
            #expect(mAh != 65)
            #expect(mAh != 100)
        }
    }

    @Test("with the mAh keys gone entirely, the capacities are absent rather than percentages")
    func missingMilliampHoursStayMissing() {
        // The case above cannot actually fail while BatteryData is present, because the correct value
        // is found before any fallback is reached — checked by mutation: adding `?? CurrentCapacity`
        // to the mAh lookup left the whole suite green. This is the input that separates them. It is
        // also the plausible next step of the change that caused this bug: iOS 27 removed four mAh
        // keys from the top level, and a release that removes BatteryData too leaves exactly this
        // registry — percentages and a cycle count.
        //
        // Absent is the right answer. A card with no Maximum Capacity row is visibly incomplete; a
        // card reading "65 mAh of 100 mAh, health 3%" is complete and wrong, and the user has no way
        // to tell.
        let stripped: [String: Any] = [
            "Serial": "FQ1HJM00D8Z0000NPM",
            "CycleCount": 106, "Voltage": 4208, "Amperage": 2310,
            "CurrentCapacity": 65, "MaxCapacity": 100,
        ]
        let b = IOSBatteryRegistry.parse(stripped)
        #expect(b.designCapacity == nil)
        #expect(b.maxCapacity == nil)
        #expect(b.nominalChargeCapacity == nil)
        #expect(b.currentCapacity == nil)
        // The percentage is still shown, because it is being read as what it is.
        #expect(abs((b.stateOfCharge ?? 0) - 65) < 0.001)
        #expect(b.cycleCount == 106)
    }

    @Test("the health figures come out as iOS's own Maximum Capacity")
    func healthMatchesWhatIOSShows() {
        // 3519/3521. iOS rounds this to 100% in Settings; the point is that it is a hair under rather
        // than absent, which is what the card showed before.
        let b = IOSBatteryRegistry.parse(Self.ios27)
        let health = BatteryHealthFigures(
            preferred: BatteryHealthFigures.percent(b.nominalChargeCapacity, of: b.designCapacity),
            raw: BatteryHealthFigures.percent(b.maxCapacity, of: b.designCapacity))
        #expect(health.maximumCapacity != nil)
        #expect((health.maximumCapacity ?? 0) > 99.9)
        #expect((health.maximumCapacity ?? 0) < 100)
        #expect(health.raw != nil)                 // 3545/3521 — a separate reading, so it is shown
    }

    // MARK: The old layout still reads the way it did

    @Test("iOS 26's top-level keys are unchanged")
    func ios26StillReads() {
        // The fallback must not have reordered anything: a device still publishing the old names has
        // to produce exactly the numbers it produced before this file existed.
        let b = IOSBatteryRegistry.parse(Self.ios26)
        #expect(b.designCapacity == 3279)
        #expect(b.maxCapacity == 3054)
        #expect(b.nominalChargeCapacity == 3061)
        #expect(b.currentCapacity == 1772)
        #expect(b.temperatureC == 29.34)
    }

    @Test("a top-level key wins over its BatteryData namesake")
    func topLevelWins() {
        // A device carrying both — which is what a transitional iOS release would look like — must
        // read the same as one carrying only the old keys, or an upgrade would move the numbers.
        var both = Self.ios26
        both["BatteryData"] = ["DesignCapacity": 1, "FullChargeCapacity": 2,
                               "NominalChargeCapacity": 3, "RemainingCapacity": 4]
        let b = IOSBatteryRegistry.parse(both)
        #expect(b.designCapacity == 3279)
        #expect(b.maxCapacity == 3054)
        #expect(b.nominalChargeCapacity == 3061)
        #expect(b.currentCapacity == 1772)
    }

    // MARK: Fields that did not move, and one that has no replacement

    @Test("cycle count, voltage and amperage are read from the top level on both layouts")
    func unmovedFieldsReadOnBothLayouts() {
        // These three stayed put across the change, which is why the card looked sparse rather than
        // empty and why the bug went unnoticed. Pinned so a later "tidy-up" does not move them into
        // the BatteryData lookup and lose them on iOS 26.
        let new = IOSBatteryRegistry.parse(Self.ios27)
        #expect(new.cycleCount == 106)
        #expect(new.voltageV == 4.208)
        #expect(new.amperageA == 2.310)
        let old = IOSBatteryRegistry.parse(Self.ios26)
        #expect(old.cycleCount == 312)
        #expect(old.voltageV == 3.950)
    }

    @Test("a discharging amperage arrives as a negative number")
    func dischargingAmperageIsSigned() {
        // IOKit reports it as unsigned 32-bit. Read unsigned, -450 mA becomes 4_294_966_846, which is
        // a 4.29 MW discharge on the card — and TemperatureAlerter's sibling reading, Temperature,
        // has the same fix-up for the same reason.
        var reg = Self.ios27
        reg["Amperage"] = 4_294_966_846        // -450 as UInt32
        #expect(IOSBatteryRegistry.parse(reg).amperageA == -0.450)
    }

    @Test("iOS 27 publishes no battery temperature, and none is invented")
    func temperatureIsAbsentOnIOS27() {
        // Absent from the top level and from every sub-dictionary. The card hides the row and
        // TemperatureAlerter never fires, which is the correct outcome: the alternative is warning a
        // user about a battery temperature derived from something that is not a temperature.
        #expect(IOSBatteryRegistry.parse(Self.ios27).temperatureC == nil)
    }

    // MARK: State of charge

    @Test("state of charge is the calibrated percentage, not the raw ratio")
    func stateOfChargeIsTheCalibratedPair() {
        // Compared with a tolerance rather than for equality: the arithmetic is cur/max*100, and
        // 58/100*100 is 57.99999999999999 in binary floating point while 65/100*100 is exactly 65.
        // The card rounds to a tenth, so neither is visible — but an exact assertion would pass for
        // one fixture and fail for the other, which reads as a bug in the parse rather than in the
        // test. This is the pre-existing expression, kept as it was; the tolerance is the test's.
        #expect(abs((IOSBatteryRegistry.parse(Self.ios27).stateOfCharge ?? 0) - 65) < 0.001)
        #expect(abs((IOSBatteryRegistry.parse(Self.ios26).stateOfCharge ?? 0) - 58) < 0.001)
    }

    @Test("a gauge reading over full is clamped to 100")
    func stateOfChargeIsClamped() {
        var reg = Self.ios27
        reg["CurrentCapacity"] = 103
        #expect(IOSBatteryRegistry.parse(reg).stateOfCharge == 100)
    }

    @Test("a zero denominator produces no percentage rather than a division")
    func zeroMaxCapacityIsRefused() {
        var reg = Self.ios27
        reg["MaxCapacity"] = 0
        reg["BatteryData"] = ["DesignCapacity": 3521]      // and no copy to fall back to
        #expect(IOSBatteryRegistry.parse(reg).stateOfCharge == nil)
    }

    // MARK: Telling a battery from a locked device

    @Test("BatteryData alone is enough to recognise a battery")
    func batteryDataIsRecognised() {
        // On iOS 27 the other four markers are down to CycleCount. If Apple drops that one too, a
        // reader keyed on the old list would decide every device is locked and show the whole card
        // as last-known — so the container itself is a marker.
        #expect(IOSBatteryRegistry.looksLikeABattery(["BatteryData": ["DesignCapacity": 3521]]))
        #expect(IOSBatteryRegistry.looksLikeABattery(Self.ios27))
        #expect(IOSBatteryRegistry.looksLikeABattery(Self.ios26))
    }

    @Test("an entry with none of the markers is not a battery", arguments: [
        [:],
        ["Serial": "F17ABC000000"],
        ["Voltage": 4208, "Amperage": 2310],     // the charger entry answers with these and no capacity
    ] as [[String: Any]])
    func unrelatedEntryIsRefused(reg: [String: Any]) {
        #expect(IOSBatteryRegistry.looksLikeABattery(reg) == false)
    }
}
