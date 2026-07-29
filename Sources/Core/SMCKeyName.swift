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
    /// happens only on a family that actually has the shape above, and any other family is returned
    /// whole. Keeping too many sensors averages a spread; keeping the wrong subset of an unfamiliar chip
    /// silently discards most of the die, and only the first of those announces itself in a comparison.
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

        // The shape test: a contiguous run of zones from 0, each publishing exactly renderings 0, 1 and
        // 2. Anything else — a stride that isn't 4, a zone missing a rendering, a family that starts at
        // an offset — is not the layout the selection below is derived from.
        let hasRenderingShape = byZone.keys.sorted() == Array(0..<byZone.count)
            && byZone.values.allSatisfy { Set($0.map { $0.rendering }) == Set([0, 1, 2]) }
        guard hasRenderingShape else { return decoded.map { $0.key }.sorted() }

        return byZone.keys.sorted().compactMap { zone in
            byZone[zone]?.first { $0.rendering == 1 }?.key
        }
    }
}
