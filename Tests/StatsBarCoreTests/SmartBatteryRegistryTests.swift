// SmartBatteryRegistryTests.swift — the key names a battery's figures arrive under.
//
// The failure this guards is not a crash and not an empty card. It is a card that keeps rendering
// perfectly while its numbers quietly stop existing, which is what iOS 27 and macOS 27 both did: the
// mAh keys moved into a BatteryData sub-dictionary, the readers went on asking for them at the top
// level, and the panels lost Maximum Capacity and every capacity row without anything going red.
//
// All five fixtures below are real. The iOS 27 pair — the AppleSmartBattery entry and the
// AppleSmartBatteryPack entry beside it — is captured verbatim from an iPhone 17 (iPhone17,3, iOS
// 27.0) over USB while charging; the macOS 27 pair from a MacBook Pro (J314s) on mains at full
// charge; the iOS 26 one is the shape both readers were written against and read against shipping
// devices for the life of this feature.

import Testing
@testable import StatsBarCore

@Suite("Smart battery registry")
struct SmartBatteryRegistryTests {

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

    /// A MacBook Pro (J314s) on macOS 27, on mains at full charge, read from the host's own IOKit.
    /// The same migration as iOS 27: among capacity keys the top level keeps only the percentage pair.
    static let macos27: [String: Any] = [
        "CycleCount": 337,
        "Voltage": 12605,
        "Amperage": 0,
        "DesignCycleCount9C": 1000,
        "IsCharging": false,
        "ExternalConnected": true,
        "FullyCharged": true,
        // Both 100 here, and both percentages, beside a 6075 mAh battery.
        "CurrentCapacity": 100,
        "MaxCapacity": 100,
        "BatteryData": [
            "AbsoluteCapacity": 0,
            "AvgTimeToEmpty": 65535,
            "CurrentCapacity": 100,
            "DesignCapacity": 6075,
            "FullChargeCapacity": 4929,
            "FullyCharged": 1,
            "MaxCapacity": 100,
            "NominalChargeCapacity": 5079,
            "RemainingCapacity": 4898,
            "TrueRemainingCapacity": 0,
        ],
    ]

    /// The gauge's own entry on the same iPhone, `ioregentry AppleSmartBatteryPack`, seconds after the
    /// entry above. It kept the vocabulary the top level lost, nested one level down, and it carries the
    /// percentage pair too. Trimmed to what this type reads plus that pair.
    static let ios27Pack: [String: Any] = [
        "Serial": "FQ1HJM00D8Z0000NPM",
        "BatteryData": [
            "Amperage": 1384,
            "AppleRawCurrentCapacity": 2628,
            "AppleRawMaxCapacity": 3541,
            "CurrentCapacity": 75,
            "CycleCount": 106,
            "DesignCapacity": 3521,
            "MaxCapacity": 100,
            "NominalChargeCapacity": 3519,
            "Serial": "FQ1HJM00D8Z0000NPM",
            "StateOfCharge": 74,
            "Temperature": 2979,
            "VirtualTemperature": 2869,
            "Voltage": 4300,
        ],
    ]

    /// The same entry on the MacBook Pro, from its own IOKit, moments after the macos27 fixture.
    static let macos27Pack: [String: Any] = [
        "Serial": "F8Y2323HM5JQ1LTAQ",
        "BatteryData": [
            "Amperage": 0,
            "AppleRawCurrentCapacity": 4898,
            "AppleRawMaxCapacity": 4929,
            "CurrentCapacity": 100,
            "CycleCount": 337,
            "DesignCapacity": 6075,
            "MaxCapacity": 100,
            "NominalChargeCapacity": 5079,
            "Serial": "F8Y2323HM5JQ1LTAQ",
            "Temperature": 3100,
            "VirtualTemperature": 3100,
            "Voltage": 12607,
        ],
    ]

    // MARK: The regression that started this

    @Test("iOS 27's capacities are found inside BatteryData")
    func ios27CapacitiesAreRead() {
        let b = SmartBatteryRegistry.parse(Self.ios27)
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
        let b = SmartBatteryRegistry.parse(Self.ios27)
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
        let b = SmartBatteryRegistry.parse(stripped)
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
        let b = SmartBatteryRegistry.parse(Self.ios27)
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
        let b = SmartBatteryRegistry.parse(Self.ios26)
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
        let b = SmartBatteryRegistry.parse(both)
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
        let new = SmartBatteryRegistry.parse(Self.ios27)
        #expect(new.cycleCount == 106)
        #expect(new.voltageV == 4.208)
        #expect(new.amperageA == 2.310)
        let old = SmartBatteryRegistry.parse(Self.ios26)
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
        #expect(SmartBatteryRegistry.parse(reg).amperageA == -0.450)
    }

    @Test("the AppleSmartBattery entry alone carries no temperature on iOS 27, and none is invented")
    func temperatureIsAbsentFromTheEntryOnIOS27() {
        // Absent from the entry's top level and from every sub-dictionary of it — it lives in the
        // pack now, see below. Without the pack the parser says nil, the card hides the row and
        // TemperatureAlerter stays quiet; the alternative was a figure derived from something that is
        // not a temperature, which is worse than an honest gap.
        #expect(SmartBatteryRegistry.parse(Self.ios27).temperatureC == nil)
    }

    // MARK: State of charge

    @Test("state of charge is the calibrated percentage, not the raw ratio")
    func stateOfChargeIsTheCalibratedPair() {
        // Compared with a tolerance rather than for equality: the arithmetic is cur/max*100, and
        // 58/100*100 is 57.99999999999999 in binary floating point while 65/100*100 is exactly 65.
        // The card rounds to a tenth, so neither is visible — but an exact assertion would pass for
        // one fixture and fail for the other, which reads as a bug in the parse rather than in the
        // test. This is the pre-existing expression, kept as it was; the tolerance is the test's.
        #expect(abs((SmartBatteryRegistry.parse(Self.ios27).stateOfCharge ?? 0) - 65) < 0.001)
        #expect(abs((SmartBatteryRegistry.parse(Self.ios26).stateOfCharge ?? 0) - 58) < 0.001)
    }

    @Test("a gauge reading over full is clamped to 100")
    func stateOfChargeIsClamped() {
        var reg = Self.ios27
        reg["CurrentCapacity"] = 103
        #expect(SmartBatteryRegistry.parse(reg).stateOfCharge == 100)
    }

    @Test("a zero denominator produces no percentage rather than a division")
    func zeroMaxCapacityIsRefused() {
        var reg = Self.ios27
        reg["MaxCapacity"] = 0
        reg["BatteryData"] = ["DesignCapacity": 3521]      // and no copy to fall back to
        #expect(SmartBatteryRegistry.parse(reg).stateOfCharge == nil)
    }

    // MARK: Telling a battery from a locked device

    @Test("BatteryData alone is enough to recognise a battery")
    func batteryDataIsRecognised() {
        // On iOS 27 the other four markers are down to CycleCount. If Apple drops that one too, a
        // reader keyed on the old list would decide every device is locked and show the whole card
        // as last-known — so the container itself is a marker.
        #expect(SmartBatteryRegistry.looksLikeABattery(["BatteryData": ["DesignCapacity": 3521]]))
        #expect(SmartBatteryRegistry.looksLikeABattery(Self.ios27))
        #expect(SmartBatteryRegistry.looksLikeABattery(Self.ios26))
    }

    @Test("an entry with none of the markers is not a battery", arguments: [
        [:],
        ["Serial": "F17ABC000000"],
        ["Voltage": 4208, "Amperage": 2310],     // the charger entry answers with these and no capacity
    ] as [[String: Any]])
    func unrelatedEntryIsRefused(reg: [String: Any]) {
        #expect(SmartBatteryRegistry.looksLikeABattery(reg) == false)
    }

    // MARK: The Mac, which had the same migration and a worse fallback

    @Test("macOS 27's capacities are found inside BatteryData")
    func macos27CapacitiesAreRead() {
        let b = SmartBatteryRegistry.parse(Self.macos27)
        #expect(b.designCapacity == 6075)
        #expect(b.maxCapacity == 4929)             // BatteryData/FullChargeCapacity
        #expect(b.nominalChargeCapacity == 5079)
        #expect(b.currentCapacity == 4898)         // BatteryData/RemainingCapacity
    }

    @Test("the Mac's percentage pair never reaches a milliamp-hour field")
    func macPercentagesAreNotMilliampHours() {
        // The shipped Mac bug was a fallback to MaxCapacity when AppleRawMaxCapacity read zero —
        // correct on Intel, where that key held mAh — which on macOS 27 drew "Full charge capacity:
        // 100 mAh" above "Design capacity: 0 mAh". This test does NOT catch a reintroduction of that
        // fallback, and saying so is the point: checked by mutation, adding `?? int(reg["MaxCapacity"])`
        // back leaves this green, because BatteryData is present here so the correct value is found
        // first. `missingMilliampHoursStayMissing` is the test that kills it, and its stripped
        // registry is the same shape on either platform. What this one pins is the weaker but still
        // worthwhile claim that a real macOS 27 registry yields four mAh figures and no percentage,
        // and that design capacity is 6075 rather than the absent-key zero the card was showing.
        let b = SmartBatteryRegistry.parse(Self.macos27)
        for mAh in [b.designCapacity, b.maxCapacity, b.nominalChargeCapacity, b.currentCapacity] {
            #expect(mAh != 100)
            #expect(mAh != 0)
            #expect(mAh != nil)
        }
    }

    @Test("a full Mac battery reports its charge in mAh, not the zeroed absolute counters")
    func macCurrentCapacityIsNotTheZeroedCounter() {
        // AbsoluteCapacity and TrueRemainingCapacity are both 0 on this machine while the battery is
        // full — the parser's choice of RemainingCapacity is argued in the type's header on iPhone
        // grounds (it shares a denominator with FullChargeCapacity), and the Mac gives the same choice
        // a second, blunter reason: the alternatives read zero on hardware that is at 100%.
        let b = SmartBatteryRegistry.parse(Self.macos27)
        #expect(b.currentCapacity == 4898)
        #expect(b.currentCapacity != 0)
        #expect(abs((b.stateOfCharge ?? 0) - 100) < 0.001)
    }

    @Test("the Mac's AppleSmartBattery entry alone carries no temperature on macOS 27 either")
    func macTemperatureIsAbsentFromTheEntry() {
        // What this pins is that the parser says nil rather than inventing a zero — the old reader
        // divided a missing key by 100 and showed 0.0 °C, which is a reading. The pack supplies it;
        // the SMC sensors in BatteryReader are the tier below that.
        #expect(SmartBatteryRegistry.parse(Self.macos27).temperatureC == nil)
    }

    @Test("the Mac's unmoved fields still read from the top level")
    func macUnmovedFieldsReadFromTheTopLevel() {
        let b = SmartBatteryRegistry.parse(Self.macos27)
        #expect(b.cycleCount == 337)
        #expect(b.voltageV == 12.605)
        #expect(b.externalConnected)
        #expect(b.fullyCharged)
        #expect(b.isCharging == false)             // on mains, but full: charging has stopped
    }

    // MARK: The pack entry, which kept the vocabulary the top level lost

    @Test("the pack's BatteryData restores the temperature on both systems")
    func packRestoresTemperature() {
        // Where it actually went. Neither iOS 27 nor macOS 27 dropped Temperature; they moved it, with
        // the AppleRaw* mAh keys, into the gauge's own entry, AppleSmartBatteryPack — nested in a
        // BatteryData of its own, under the OLD names. The first sweep for it concluded it was gone,
        // because it chose entries to read from the IOPower plane and the pack is not power-managed.
        // Centi-degrees like the key it replaces: 2979 is 29.79 °C on a phone charging at 9 W.
        #expect(SmartBatteryRegistry.parse(Self.ios27, pack: Self.ios27Pack).temperatureC == 29.79)
        #expect(SmartBatteryRegistry.parse(Self.macos27, pack: Self.macos27Pack).temperatureC == 31.00)
    }

    @Test("the entry is asked first; the pack answers only for what the entry lacks")
    func entryWinsOverPack() {
        // A pack that disagrees with the entry must lose, or attaching the pack would move numbers the
        // card already showed correctly. On the measured iPhone the two really do differ by a few mAh
        // (entry FullChargeCapacity 3545, pack AppleRawMaxCapacity 3541): one gauge, sampled apart.
        var pack = Self.ios27Pack
        var pd = pack["BatteryData"] as! [String: Any]
        pd["DesignCapacity"] = 1; pd["AppleRawMaxCapacity"] = 2; pd["AppleRawCurrentCapacity"] = 3
        pd["NominalChargeCapacity"] = 4; pd["CycleCount"] = 5; pd["Voltage"] = 6
        pack["BatteryData"] = pd
        let b = SmartBatteryRegistry.parse(Self.ios27, pack: pack)
        #expect(b.designCapacity == 3521)
        #expect(b.maxCapacity == 3545)
        #expect(b.currentCapacity == 2281)
        #expect(b.nominalChargeCapacity == 3519)
        #expect(b.cycleCount == 106)
        #expect(b.voltageV == 4.208)
        #expect(b.temperatureC == 29.79)           // the one thing the entry could not supply
    }

    @Test("the pack's percentage pair never reaches a milliamp-hour field either")
    func packPercentagesAreNotMilliampHours() {
        // Third copy of the trap: the pack's BatteryData also carries CurrentCapacity 75 and
        // MaxCapacity 100. With the entry stripped to nothing but percentages, every mAh figure has to
        // come from the pack's AppleRaw* keys — the same names the top level used to have.
        let stripped: [String: Any] = ["CurrentCapacity": 65, "MaxCapacity": 100, "CycleCount": 106]
        let b = SmartBatteryRegistry.parse(stripped, pack: Self.ios27Pack)
        #expect(b.designCapacity == 3521)
        #expect(b.maxCapacity == 3541)             // pack AppleRawMaxCapacity, not MaxCapacity
        #expect(b.currentCapacity == 2628)         // pack AppleRawCurrentCapacity, not CurrentCapacity
        #expect(b.nominalChargeCapacity == 3519)
        for mAh in [b.designCapacity, b.maxCapacity, b.nominalChargeCapacity, b.currentCapacity] {
            #expect(mAh != 75)
            #expect(mAh != 100)
        }
    }

    @Test("a pack whose mAh keys are gone leaves the capacities absent")
    func packWithoutMilliampHoursStaysMissing() {
        // The mutant the test above cannot catch — falling back to the pack's CurrentCapacity once its
        // AppleRaw* keys are gone — because with them present the right value is found first. Same
        // shape as missingMilliampHoursStayMissing, one tier further down the chain.
        let stripped: [String: Any] = ["CurrentCapacity": 65, "MaxCapacity": 100, "CycleCount": 106]
        let pack: [String: Any] = ["BatteryData": ["CurrentCapacity": 75, "MaxCapacity": 100, "Temperature": 2979]]
        let b = SmartBatteryRegistry.parse(stripped, pack: pack)
        #expect(b.designCapacity == nil)
        #expect(b.maxCapacity == nil)
        #expect(b.currentCapacity == nil)
        #expect(b.temperatureC == 29.79)           // the pack still gives what it has
    }

    @Test("the reader is told to fetch the pack exactly when the entry lacks what the pack has")
    func wantsPackOnlyWhenTheEntryIsShort() {
        // One more subprocess per read on an iPhone, so it is not free, and iOS 26 must never pay it.
        #expect(SmartBatteryRegistry.wantsPack(Self.ios26) == false)
        #expect(SmartBatteryRegistry.wantsPack(Self.ios27))
        #expect(SmartBatteryRegistry.wantsPack(Self.macos27))
    }
}
