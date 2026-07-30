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

    @Test("a Tp family where nothing decodes is nil, not an empty list")
    func undecodableFamilyIsAlsoTheIntelSignal() {
        // Tp-shaped names that carry no usable index are worth exactly as much as no family at all, so
        // the answer has to be nil: an empty array would leave CPUReader with a list it can read nothing
        // from and no reason to try the TC** probe, i.e. no temperature anywhere in the UI.
        #expect(SMCKeyName.cpuThermalKeys(from: ["Tp-!", "Tp  "]) == nil)
    }

    @Test("falls back to every Tp key when none sit at rendering 1")
    func fallsBackToAllTpKeys() {
        // An unfamiliar chip that numbers its zones differently still gets a temperature — averaged over
        // whatever it does publish — rather than none.
        #expect(SMCKeyName.cpuThermalKeys(from: ["Tp02", "Tp00"]) == ["Tp00", "Tp02"])
    }

    @Test("a contiguous Tp family is kept whole rather than thinned to a quarter of the die")
    func contiguousFamilyIsNotThinned() {
        // The case the shape test exists for. A one-sensor-per-zone chip numbers its keys 0,1,2,3,…, and
        // a bare `index % 4 == 1` filter accepts two of those eight and reports them as the whole die —
        // an average over a quarter of the chip, printed as a perfectly plausible °C. Nothing downstream
        // can tell: CPUSection would draw two cells for an eight-core part and nobody counts cells.
        let contiguous = ["Tp00", "Tp01", "Tp02", "Tp03", "Tp04", "Tp05", "Tp06", "Tp07"]
        #expect(SMCKeyName.cpuThermalKeys(from: contiguous) == contiguous)
    }

    @Test("a three-per-zone family that starts at an offset is kept whole")
    func offsetFamilyIsNotThinned() {
        // Renderings-shaped, but the groups begin at 2 rather than at a multiple of 4, so `index / 4`
        // splits them across zone boundaries and no selection derived from that grouping is trustworthy.
        // Returning everything averages the three redundant renderings — wrong by the ~9 °C this file is
        // about — but wrong in the direction that shows up if anyone ever compares two chips, rather
        // than the direction that quietly discards sensors.
        let offset = ["Tp02", "Tp03", "Tp04", "Tp06", "Tp07", "Tp08"]
        #expect(SMCKeyName.cpuThermalKeys(from: offset) == offset)
    }

    @Test("one junk name does not stop the real family being thinned")
    func aSingleJunkKeyDoesNotDisableSelection() {
        // The shape is judged on the names that decode, not on every Tp-prefixed string present. An M1
        // Pro that also published something unreadable must still collapse to its ten zones, because the
        // alternative — falling back to all thirty — is the ~9 °C averaging error.
        //
        // Note this is the WEAK version of that guard: "Tp-!" is dropped by `index` before the shape is
        // ever looked at, so a check that judged the family as one unit would pass it too. The two tests
        // below are the ones that need the per-zone split, and they are where the ~9 °C actually hid.
        #expect(SMCKeyName.cpuThermalKeys(from: Self.m1ProTpKeys + ["Tp-!"]) == Self.expectedZoneKeys)
    }

    // MARK: one anomaly must cost one zone, not the whole die

    @Test("a stray key that DOES decode costs only its own zone")
    func aDecodableStrayKeyCostsOneZone() {
        // The failure this file was written to prevent, reached from the one direction the junk-key test
        // above cannot reach. "Tp0d" is index 39 — zone 9, rendering 3 — so unlike "Tp-!" it survives
        // decoding and lands inside the family. Judged family-wide, that single key made zone 9 fail the
        // renderings test and dropped the thinning for ALL ten zones: measured against the pre-fix code,
        // 31 keys came back instead of 10, i.e. every CORES cell and the headline CPU temperature
        // averaging three redundant renderings, ~9 °C out, for the whole session.
        //
        // It is not a hypothetical key. SMC.allKeyNames() skips any index whose read fails rather than
        // reporting a short list, and CPUReader.discoverTemperatureKeys runs once at launch — so one
        // hiccup in that single enumeration is enough, and nothing afterwards re-derives the list.
        let out = SMCKeyName.cpuThermalKeys(from: Self.m1ProTpKeys + ["Tp0d"])
        #expect(out == ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X",
                        "Tp0a", "Tp0b", "Tp0c", "Tp0d"])
        // Nine zones still thinned to one key each; only zone 9 keeps all four of its own.
        #expect(out?.count == 13)
    }

    @Test("a zone that lost a rendering costs only its own zone")
    func aMissingRenderingCostsOneZone() {
        // The same failure from the opposite direction: a key going MISSING rather than appearing. Zone 0
        // is left with renderings 0 and 1, which is not the triple, so it keeps both — but zones 1 through
        // 9 are untouched and must still collapse. Family-wide this returned 29 keys.
        let out = SMCKeyName.cpuThermalKeys(from: Self.m1ProTpKeys.filter { $0 != "Tp02" })
        #expect(out == ["Tp00", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T",
                        "Tp0X", "Tp0b"])
        #expect(out?.count == 11)
    }

    @Test("zones need not be numbered contiguously to be thinned")
    func nonContiguousZonesAreStillThinned() {
        // Zones 0, 1 and 3 with a hole where zone 2 would be — the shape a part with a disabled cluster
        // could plausibly publish. All three present zones hold the full triple, so all three collapse.
        // The previous whole-family test additionally demanded the zone numbers run 0..<count and
        // returned all nine keys here, which is the averaging error for no benefit.
        let gapped = ["Tp00", "Tp01", "Tp02", "Tp04", "Tp05", "Tp06", "Tp0C", "Tp0D", "Tp0E"]
        #expect(SMCKeyName.cpuThermalKeys(from: gapped) == ["Tp01", "Tp05", "Tp0D"])
    }

    @Test("a family whose stride is not 4 is kept whole, however its groups fall")
    func strideThatIsNotFourIsKeptWhole() {
        // Tp00…Tp06 splits under `index / 4` into a group of four and a group of three. The group of three
        // looks like a rendering triple all by itself, so a purely per-zone rule would thin it and throw
        // away two of seven sensors. It must not: a stride that isn't 4 means the zone arithmetic itself
        // is wrong for this family, and the strict majority is what refuses it — one shaped group out of
        // two is not a majority. This is the case that keeps the fix from trading one silent loss for
        // another.
        let sevenInARow = ["Tp00", "Tp01", "Tp02", "Tp03", "Tp04", "Tp05", "Tp06"]
        #expect(SMCKeyName.cpuThermalKeys(from: sevenInARow) == sevenInARow)
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
