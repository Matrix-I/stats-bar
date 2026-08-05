// AccessoryBatteryJoinTests.swift — attributing macOS's accessory battery records to the right rows
// of the Bluetooth popover.
//
// The bug this join was written for was a MISSING SOURCE, not bad arithmetic: a Sony WH-CH520 showed
// "—" for four releases while macOS knew it was at 70%. No test can catch a source nobody queries.
// What tests CAN hold is the part that replaced the previous [name: percent] dictionary, and the two
// ways that dictionary was wrong — both of which print a plausible percentage rather than failing.
//
// The fixture is the author's machine at the moment the bug was reported, ID for ID: the numbers
// below are what `pmset -g accps` and `system_profiler SPBluetoothDataType -json` actually returned,
// including the keyboard that reports no vendor/product IDs and the trailing space in its name. A
// fixture invented to suit the code would have had neither, and both are load-bearing here.

import Testing
@testable import StatsBarCore

@Suite("Accessory battery join")
struct AccessoryBatteryJoinTests {

    // The three devices as system_profiler describes them, with the hex IDs already decoded
    // (0x046D → 1133, 0xB025 → 45093, 0x054C → 1356, 0x0EAD → 3757).
    static let mouse = DeviceIdentity(name: "MX Anywhere 3 Mac", vendorID: 1133, productID: 45093)
    static let keyboard = DeviceIdentity(name: "R65 5.0")          // reports no IDs at all
    static let headset = DeviceIdentity(name: "WH-CH520", vendorID: 1356, productID: 3757)

    // The same three as the accessory power sources describe them. Note the keyboard's trailing
    // space, which is present on both sides and belongs to neither.
    static let records = [
        AccessoryBattery(name: "MX Anywhere 3 Mac", vendorID: 1133, productID: 45093, percent: 90),
        AccessoryBattery(name: "R65 5.0 ", vendorID: 13652, productID: 64007, percent: 100),
        AccessoryBattery(name: "WH-CH520", vendorID: 1356, productID: 3757, percent: 70),
    ]

    // MARK: The reported bug

    @Test("the headset that showed a dash is attributed 70%")
    func theReportedDeviceGetsItsLevel() {
        let out = AccessoryBatteryJoin.levels(devices: [Self.mouse, Self.keyboard, Self.headset],
                                              accessories: Self.records)
        #expect(out[0].main == 90)
        #expect(out[1].main == 100)   // matched on its name; it has no IDs to match on
        #expect(out[2].main == 70)    // the row that read "—"
        #expect(out.allSatisfy { $0.left == nil && $0.right == nil && $0.caseLevel == nil })
    }

    @Test("a device no accessory record covers is left empty rather than given someone else's level")
    func unmatchedDevicesStayEmpty() {
        let stranger = DeviceIdentity(name: "EMBERTON")
        let out = AccessoryBatteryJoin.levels(devices: [stranger, Self.headset], accessories: Self.records)
        #expect(out[0] == AccessoryLevels())
        #expect(out[0].isEmpty)
        #expect(out[1].main == 70)
    }

    // MARK: What the [name: percent] dictionary got wrong

    /// Two of the same mouse. This is the realistic collision and not a contrived one — identical
    /// hardware reports an identical name AND an identical vendor/product pair, so it defeats every
    /// key the join has. Written with IDs deliberately: an earlier version of these cases used
    /// nameless devices, which routed them through the name pass and left the ID pass's own
    /// claim guard covered by nothing. Mutation testing found that; reading the tests did not.
    static let twins = [
        DeviceIdentity(name: "MX Anywhere 3 Mac", vendorID: 1133, productID: 45093),
        DeviceIdentity(name: "MX Anywhere 3 Mac", vendorID: 1133, productID: 45093),
    ]

    @Test("one accessory is never reported as the battery of two devices")
    func anAccessoryIsClaimedOnce() {
        // The defect in the shape this replaced. A dictionary keyed by name is a TOTAL relation, so
        // both rows read the same number and each looked measured. Only one of them can be right,
        // and nothing on screen says which — so the second row must show nothing.
        let one = [AccessoryBattery(name: "MX Anywhere 3 Mac", vendorID: 1133, productID: 45093, percent: 42)]
        let out = AccessoryBatteryJoin.levels(devices: Self.twins, accessories: one)
        #expect(out[0].main == 42)
        #expect(out[1].isEmpty)
    }

    @Test("two identical devices pair off with two records instead of both taking the first")
    func identicalDevicesPairInOrder() {
        let two = [AccessoryBattery(name: "MX Anywhere 3 Mac", vendorID: 1133, productID: 45093, percent: 42),
                   AccessoryBattery(name: "MX Anywhere 3 Mac", vendorID: 1133, productID: 45093, percent: 77)]
        let out = AccessoryBatteryJoin.levels(devices: Self.twins, accessories: two)
        #expect(out[0].main == 42)
        #expect(out[1].main == 77)
    }

    @Test("two nameless-ID devices also claim one record each, through the other pass")
    func identicalDevicesWithoutIDsAlsoPairOff() {
        // The same collision one key weaker, so the name pass carries its own claim guard rather
        // than inheriting coverage from the ID pass above.
        let twins = [DeviceIdentity(name: "Beats"), DeviceIdentity(name: "Beats")]
        let two = [AccessoryBattery(name: "Beats", percent: 30),
                   AccessoryBattery(name: "Beats", percent: 65)]
        let out = AccessoryBatteryJoin.levels(devices: twins, accessories: two)
        #expect(out[0].main == 30)
        #expect(out[1].main == 65)
    }

    @Test("a multi-part accessory folds into one row instead of overwriting itself")
    func multiPartFoldsIntoOneDevice() {
        // The other defect: macOS publishes earbuds as several records differing only in
        // `Part Identifier`. Keyed by name they collapse onto one entry and whichever arrived last
        // wins, so a row shows the case level as though it were the buds'.
        let buds = DeviceIdentity(name: "AirPods Pro", vendorID: 76, productID: 8207)
        let parts = [
            AccessoryBattery(name: "AirPods Pro", vendorID: 76, productID: 8207, part: .left, percent: 80),
            AccessoryBattery(name: "AirPods Pro", vendorID: 76, productID: 8207, part: .right, percent: 78),
            AccessoryBattery(name: "AirPods Pro", vendorID: 76, productID: 8207, part: .caseUnit, percent: 95),
        ]
        let out = AccessoryBatteryJoin.levels(devices: [buds], accessories: parts)
        #expect(out[0] == AccessoryLevels(main: nil, left: 80, right: 78, caseLevel: 95))
    }

    // MARK: Which key wins

    @Test("IDs are matched completely before any name is considered")
    func idsBeatNames() {
        // A constructed conflict, because the invariant is about pass ORDER and nothing on this
        // machine exercises it: the single record's name matches the first device while its IDs
        // match the second. Trying both keys per device — the obvious one-loop version — hands it to
        // the first device on the strength of a name. IDs are the stronger evidence, so it belongs
        // to the second, and the first must be left empty.
        let named = DeviceIdentity(name: "Shared Name")
        let identified = DeviceIdentity(name: "Something Else", vendorID: 1, productID: 2)
        let one = [AccessoryBattery(name: "Shared Name", vendorID: 1, productID: 2, percent: 55)]
        let out = AccessoryBatteryJoin.levels(devices: [named, identified], accessories: one)
        #expect(out[0].isEmpty)
        #expect(out[1].main == 55)
    }

    @Test("names match across the trailing space and the casing neither side owns")
    func nameMatchingIsNormalised() {
        // Real data: system_profiler and the accessory channel both report the keyboard as
        // "R65 5.0 ". If either ever stops, or changes case, the row must not go blank.
        let device = DeviceIdentity(name: "  r65 5.0")
        let record = [AccessoryBattery(name: "R65 5.0 ", percent: 100)]
        #expect(AccessoryBatteryJoin.levels(devices: [device], accessories: record)[0].main == 100)
    }

    @Test("a device with no name at all matches nothing rather than every unnamed record")
    func emptyNamesDoNotMatch() {
        let nameless = DeviceIdentity(name: "   ")
        let record = [AccessoryBattery(name: "", percent: 50)]
        #expect(AccessoryBatteryJoin.levels(devices: [nameless], accessories: record)[0].isEmpty)
    }

    // MARK: Reading a record

    @Test("a percentage is a ratio of the capacity pair, not the raw number")
    func percentIsARatio() {
        // Accessories report Max Capacity as 100, so this is the identity for every record observed.
        #expect(AccessoryBattery.percent(current: 70, maxCapacity: 100) == 70)
        // But the same two keys carry mAh for the Mac's own battery. Taking Current Capacity at face
        // value would print "350%" the day macOS publishes an accessory that way.
        #expect(AccessoryBattery.percent(current: 350, maxCapacity: 500) == 70)
        #expect(AccessoryBattery.percent(current: 3, maxCapacity: 8) == 38)   // rounded, not truncated
    }

    @Test("an unusable capacity pair yields no reading rather than a wrong one")
    func percentRejectsNonsense() {
        #expect(AccessoryBattery.percent(current: 50, maxCapacity: 0) == nil)   // would divide by zero
        #expect(AccessoryBattery.percent(current: -1, maxCapacity: 100) == nil)
        #expect(AccessoryBattery.percent(current: 120, maxCapacity: 100) == 100) // clamped, not dropped
    }

    @Test("an absent Part Identifier is a single-battery device, which is the common case")
    func partDefaultsToSingle() {
        // The key is missing entirely from the records macOS publishes for BLE accessories and reads
        // "Single" on the classic ones — so a reading must never be dropped for want of a label.
        #expect(AccessoryBattery.part(nil) == .single)
        #expect(AccessoryBattery.part("Single") == .single)
        #expect(AccessoryBattery.part("left") == .left)
        #expect(AccessoryBattery.part(" RIGHT ") == .right)
        #expect(AccessoryBattery.part("Case") == .caseUnit)
        #expect(AccessoryBattery.part("Nacelle") == .single)
    }
}
