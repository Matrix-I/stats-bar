// SMCKeyName.swift — arithmetic on SMC key *names*: decoding the numeric suffix, and picking one
// CPU temperature key per thermal zone out of the redundant family the SMC publishes.
//
// Split out of CPUReader because none of it touches hardware — every function here is names in,
// names out. That makes it the one part of the temperature path a unit test can pin down (the reads
// themselves need the machine's own SMC), which is what SMCKeyNameTests covers. CPUReader.swift
// documents what the selected keys mean and how the zone→core question was measured; this file only
// documents how the names are counted.

import Foundation

enum SMCKeyName {
    /// The alphabet the SMC counts key indices in — decimal digits, then upper case, then lower.
    private static let base62 = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// The two-character numeric suffix of a 4-char SMC key, as a number. nil when either character
    /// falls outside the alphabet, so a key that doesn't follow the convention is skipped rather than
    /// silently mis-grouped.
    static func index(_ key: String) -> Int? {
        let suffix = Array(key.dropFirst(2))
        guard suffix.count == 2,
              let hi = base62.firstIndex(of: suffix[0]),
              let lo = base62.firstIndex(of: suffix[1]) else { return nil }
        return hi * 62 + lo
    }

    /// One CPU-die temperature key per thermal zone, in zone order, out of every key name the SMC
    /// publishes — or nil when the machine exposes no usable `Tp..` family (an Intel Mac), which is the
    /// caller's signal to probe the classic TC** keys instead.
    ///
    /// On an Apple Silicon die there are three Tp keys per zone, not one: `index / 4` is the zone and
    /// `index % 4` the rendering within it, renderings 0, 1 and 2 present and 3 unused. Rendering 1 is
    /// the one taken — the three differ by ~9 °C, so averaging them all is wrong by that much, which is
    /// the whole reason this function exists. CPUReader.discoverTemperatureKeys records the measurements.
    ///
    /// The layout is CHECKED rather than assumed, because a name cannot say whether `Tp00…Tp07` is eight
    /// zones or eight renderings of one — that information is not in the SMC's key list. So the thinning
    /// happens only on a family that actually has the shape above, and anything else is returned whole.
    /// Keeping too many sensors averages a spread; keeping the wrong subset of an unfamiliar chip silently
    /// discards most of the die, and only the first of those announces itself in a comparison.
    ///
    /// The check is deliberately split across two levels, and that split is the point rather than a
    /// refinement. WHETHER the renderings model applies is a question about the whole family, because one
    /// zone holding three keys is equally consistent with three zones holding one each — a single zone
    /// cannot answer it. WHICH keys to drop is a question about each zone on its own. Judging both
    /// family-wide, as this first did, made one stray or one missing key disable the thinning for every
    /// zone: on this M1 Pro's real thirty-key family, adding a decodable `Tp0d` returned all 31 keys
    /// instead of 10, and losing `Tp02` returned 29 — in both cases averaging the three renderings the
    /// function exists to separate, wrong by that ~9 °C. Neither is hypothetical:
    /// `SMC.allKeyNames()` skips any index whose read fails rather than reporting a short list, and
    /// `CPUReader.discoverTemperatureKeys` runs once at launch, so a single hiccup during that one
    /// enumeration would have mis-read every temperature for the rest of the session.
    static func cpuThermalKeys(from all: [String]) -> [String]? {
        let apple = all.filter { $0.count == 4 && $0.hasPrefix("Tp") }
        guard !apple.isEmpty else { return nil }

        // A name whose suffix is outside the alphabet has no zone, and feeding it to the per-second read
        // loop would only fail every tick — so it is not a candidate. If NONE of them decode, there is no
        // family here worth reading and nil sends the caller to the TC** probe.
        let decoded = apple.compactMap { key -> (key: String, zone: Int, rendering: Int)? in
            guard let i = index(key) else { return nil }
            return (key, i / 4, i % 4)
        }
        guard !decoded.isEmpty else { return nil }
        let byZone = Dictionary(grouping: decoded) { $0.zone }
        func isRenderingTriple(_ keys: [(key: String, zone: Int, rendering: Int)]) -> Bool {
            Set(keys.map { $0.rendering }) == Set([0, 1, 2])
        }

        // Family level: accept the model only on a STRICT majority, so a lone three-key group can't
        // establish it. `Tp00 Tp01 Tp02` alone is as likely to be three zones as one, and `Tp00…Tp06`
        // splits into a group of four and a group of three — a stride that isn't 4, so the zone arithmetic
        // itself is wrong there and nothing may be dropped. A real renderings family is overwhelmingly
        // shaped this way (ten zones out of ten here), so a majority is a low bar to clear honestly.
        let shaped = byZone.values.filter(isRenderingTriple).count
        guard shaped * 2 > byZone.count else { return decoded.map { $0.key }.sorted() }

        // Zone level: thin the zones that fit, keep whole the ones that don't. An anomaly now costs its
        // own zone and nothing else, which is the difference between one cell of the CORES grid reading a
        // three-way average and all of them doing so.
        return byZone.keys.sorted().flatMap { zone -> [String] in
            guard let keys = byZone[zone] else { return [] }
            if isRenderingTriple(keys), let one = keys.first(where: { $0.rendering == 1 }) {
                return [one.key]
            }
            return keys.map { $0.key }.sorted()
        }
    }
}
