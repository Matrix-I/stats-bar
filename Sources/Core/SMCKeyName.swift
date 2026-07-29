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
    /// publishes — or nil on a machine that exposes no `Tp..` family at all (an Intel Mac), which is
    /// the caller's signal to probe the classic TC** keys instead.
    ///
    /// There are three Tp keys per zone, not one, and `index / 4` is the zone with `index % 4` the
    /// rendering within it. Rendering 1 is the one taken. Falls back to every Tp key, name-sorted,
    /// when nothing matches that pattern, so an unfamiliar chip still gets a temperature rather than
    /// none. CPUReader.discoverTemperatureKeys records the measurements behind those choices.
    static func cpuThermalKeys(from all: [String]) -> [String]? {
        let apple = all.filter { $0.count == 4 && $0.hasPrefix("Tp") }
        guard !apple.isEmpty else { return nil }
        let zones = apple.filter { (index($0) ?? 0) % 4 == 1 }
        guard !zones.isEmpty else { return apple.sorted() }
        return zones.sorted { (index($0) ?? 0) < (index($1) ?? 0) }
    }
}
