// SMCKeyNameTests.swift — the CPU temperature key selection, which is the half of the temperature
// path that runs without an SMC.
//
// The reason to test it: the die publishes three redundant renderings per thermal zone, and picking
// the wrong subset produces temperatures that are wrong by ~9 °C while looking entirely plausible
// (Tp00 / Tp01 / Tp02 measured 51.20 / 60.20 / 67.34 at idle on this M1 Pro). Nothing in the UI would
// flag that. The key family below is the real one this machine enumerates.

import Testing
@testable import StatsBarCore

@Suite("SMC key names")
struct SMCKeyNameTests {

    /// Every `Tp..` key an M1 Pro publishes: ten thermal zones × three renderings, hence indices
    /// 0,1,2 · 4,5,6 · 8,9,10 · … · 36,37,38 rather than a contiguous run.
    static let m1ProTpKeys = [
        "Tp00", "Tp01", "Tp02",
        "Tp04", "Tp05", "Tp06",
        "Tp08", "Tp09", "Tp0A",
        "Tp0C", "Tp0D", "Tp0E",
        "Tp0G", "Tp0H", "Tp0I",
        "Tp0K", "Tp0L", "Tp0M",
        "Tp0O", "Tp0P", "Tp0Q",
        "Tp0S", "Tp0T", "Tp0U",
        "Tp0W", "Tp0X", "Tp0Y",
        "Tp0a", "Tp0b", "Tp0c",
    ]

    /// The ten keys that must come out — one per zone, rendering 1.
    static let expectedZoneKeys = [
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X", "Tp0b",
    ]

    // MARK: index — base-62 decoding

    @Test("index decodes each stretch of the alphabet", arguments: [
        ("Tp00", 0),
        ("Tp09", 9),    // last digit
        ("Tp0A", 10),   // first upper case
        ("Tp0Z", 35),   // last upper case
        ("Tp0a", 36),   // first lower case
        ("Tp0z", 61),   // last lower case
    ])
    func indexDecodesAlphabet(key: String, expected: Int) {
        // The digit→upper→lower boundaries are exactly where an off-by-one would hide.
        #expect(SMCKeyName.index(key) == expected)
    }

    @Test("index carries into the high digit")
    func indexCarries() {
        // Base 62, not "second character only" — this is what keeps zone 15 and beyond correct on a
        // chip with more thermal zones than this one.
        #expect(SMCKeyName.index("Tp10") == 62)
        #expect(SMCKeyName.index("Tp11") == 63)
        #expect(SMCKeyName.index("Tpzz") == 61 * 62 + 61)
    }

    @Test("index rejects keys outside the convention", arguments: [
        "Tp0-", "Tp0 ", "Tp0", "Tp0000",
    ])
    func indexRejectsMalformed(key: String) {
        // nil rather than a guessed number: a key outside the scheme must be skipped, not silently
        // mis-grouped into some zone.
        #expect(SMCKeyName.index(key) == nil)
    }

    @Test("the selected keys are rendering 1 of zones 0 through 9")
    func selectedKeysAreRenderingOne() {
        // The whole selection rule, stated as arithmetic rather than as a list.
        let zones = Self.expectedZoneKeys.map { SMCKeyName.index($0)! }
        #expect(zones == [1, 5, 9, 13, 17, 21, 25, 29, 33, 37])
        #expect(zones.map { $0 % 4 } == Array(repeating: 1, count: 10))
        #expect(zones.map { $0 / 4 } == Array(0..<10))
    }

    // MARK: cpuThermalKeys — one key per zone

    @Test("picks one key per zone out of the full Apple family")
    func picksOnePerZone() {
        // Thirty keys in, ten out. Keeping all thirty averages three different quantities together;
        // taking rendering 0 or 2 instead shifts every reading by ~9 °C.
        #expect(SMCKeyName.cpuThermalKeys(from: Self.m1ProTpKeys) == Self.expectedZoneKeys)
    }

    @Test("ignores every other key the SMC publishes")
    func ignoresUnrelatedKeys() {
        // The real input is the machine's whole key list — fans, power rails, battery, other sensors.
        let all = ["PSTR", "F0Ac", "F0Mx", "B0AC", "TB0T", "TG0D", "VP0R"]
                  + Self.m1ProTpKeys + ["TC0P", "TC0D"]
        #expect(SMCKeyName.cpuThermalKeys(from: all.shuffled()) == Self.expectedZoneKeys)
    }

    @Test("output is in zone order regardless of input order")
    func outputIsInZoneOrder() {
        // Zone order is what keeps each CORES cell showing the same zone from tick to tick instead of
        // reshuffling as zones overtake one another. (Note: for this alphabet a plain name sort happens
        // to agree, since ASCII orders digits < upper < lower the same way base 62 does — so this pins
        // the output, not the necessity of sorting by index.)
        #expect(SMCKeyName.cpuThermalKeys(from: Self.m1ProTpKeys.reversed()) == Self.expectedZoneKeys)
        #expect(SMCKeyName.cpuThermalKeys(from: Self.m1ProTpKeys.shuffled()) == Self.expectedZoneKeys)
    }

    @Test("keys of the wrong length are not treated as temperature keys")
    func rejectsWrongLength() {
        // Guards the `count == 4` filter: the SMC's key list is trusted input, but a truncated or padded
        // name must not slip into the per-second read loop.
        #expect(SMCKeyName.cpuThermalKeys(from: ["Tp0", "Tp01", "Tp0Hx", "Tp"]) == ["Tp01"])
    }

    @Test("a malformed Tp key is not selected as a zone")
    func malformedTpKeyIsDropped() {
        // A Tp key whose suffix is outside the alphabet decodes to nil. It must drop out rather than
        // default into zone 0 — index 0 is a real zone that a real key already owns.
        #expect(SMCKeyName.cpuThermalKeys(from: ["Tp01", "Tp-!", "Tp05"]) == ["Tp01", "Tp05"])
    }

    // MARK: cpuThermalKeys — the two fallbacks

    @Test("returns nil when the machine publishes no Apple family")
    func nilIsTheIntelSignal() {
        // nil tells CPUReader to go probe the classic TC** keys. An empty array instead would leave an
        // Intel Mac with no temperature at all.
        #expect(SMCKeyName.cpuThermalKeys(from: ["TC0P", "TC0D", "TC1C", "PSTR"]) == nil)
        #expect(SMCKeyName.cpuThermalKeys(from: []) == nil)
    }

    @Test("falls back to every Tp key when none sit at rendering 1")
    func fallsBackToAllTpKeys() {
        // An unfamiliar chip that numbers its zones differently still gets a temperature — averaged over
        // whatever it does publish — rather than none.
        #expect(SMCKeyName.cpuThermalKeys(from: ["Tp02", "Tp00"]) == ["Tp00", "Tp02"])
    }

    @Test("the fallback list also excludes keys of the wrong length")
    func fallbackAlsoRejectsWrongLength() {
        // rejectsWrongLength above only exercises the zones path, where an over-long key is dropped
        // incidentally rather than by the length filter: `index` needs exactly a two-character suffix,
        // so it decodes to nil, becomes 0 via `?? 0`, and fails `% 4 == 1` whatever the filter does.
        // The fallback returns `apple` itself, so `count == 4` is the ONLY thing keeping a malformed
        // name out of the per-second SMC read loop — and the fallback is the path an unfamiliar chip
        // takes, which is precisely where a malformed name is most likely to turn up.
        #expect(SMCKeyName.cpuThermalKeys(from: ["Tp00", "Tp02", "Tp0Hxx"]) == ["Tp00", "Tp02"])
    }
}
