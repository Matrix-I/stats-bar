// CPUFrequency.swift — per-cluster CPU clock speed (MHz) from the private IOReport framework, the
// only way to read real Apple-Silicon frequencies without sudo (powermetrics needs root).
//
// It subscribes ONCE to the "CPU Complex Performance States" channels, then each sample() diffs the
// residency counters against the previous sample and computes, per cluster, the active-residency-
// weighted average frequency — i.e. of the time the cluster was NOT idle, the mean of the DVFS-state
// frequencies weighted by how long it sat in each. The state index → MHz mapping comes from the
// pmgr node's "voltage-states" tables (voltage-states1 = efficiency, voltage-states5 = performance),
// where each 8-byte entry is (rawPeriod, voltage) little-endian and MHz = 65_536_000 / rawPeriod
// (verified against the M1 Pro's known 600–2064 / 600–3228 MHz ranges).
//
// Everything here rests on private symbols and undocumented layouts, so it fails soft: if the
// library, a symbol, the channels, the subscription, or the DVFS tables are missing (a future
// macOS, or an Intel Mac), isAvailable stays false and sample() returns nil and the UI hides the
// FREQUENCY section rather than showing garbage.

import Foundation
import IOKit

final class CPUFrequency {
    struct Reading {
        let allMHz: Double
        let efficiencyMHz: Double
        let performanceMHz: Double
    }

    private(set) var isAvailable = false

    // IOReport function-pointer typedefs (reverse-engineered; stable across recent macOS releases).
    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamples = @convention(c) (AnyObject?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetChannelName = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateGetCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetNameForIndex = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias IterateFn = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void

    private var createSamples: CreateSamples?
    private var createDelta: CreateSamplesDelta?
    private var getName: GetChannelName?
    private var stateCount: StateGetCount?
    private var stateName: StateGetNameForIndex?
    private var stateResidency: StateGetResidency?
    private var iterate: IterateFn?

    private var subscription: AnyObject?
    private var subbed: CFMutableDictionary?
    private var prevSample: CFDictionary?

    private var eTable: [Double] = []   // efficiency-cluster DVFS frequencies (MHz), index-aligned
    private var pTable: [Double] = []   // performance-cluster DVFS frequencies (MHz)

    init() {
        setup()
    }

    private func setup() {
        eTable = Self.readVoltageStates("voltage-states1")
        pTable = Self.readVoltageStates("voltage-states5")
        guard !eTable.isEmpty || !pTable.isEmpty else { return }

        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func fn<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let copyChannels = fn("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let createSub = fn("IOReportCreateSubscription", CreateSubscription.self),
              let createSamples = fn("IOReportCreateSamples", CreateSamples.self),
              let createDelta = fn("IOReportCreateSamplesDelta", CreateSamplesDelta.self),
              let getName = fn("IOReportChannelGetChannelName", GetChannelName.self),
              let stateCount = fn("IOReportStateGetCount", StateGetCount.self),
              let stateName = fn("IOReportStateGetNameForIndex", StateGetNameForIndex.self),
              let stateResidency = fn("IOReportStateGetResidency", StateGetResidency.self),
              let iterate = fn("IOReportIterate", IterateFn.self)
        else { return }

        guard let ch = copyChannels("CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() else { return }
        var subbedRaw: Unmanaged<CFMutableDictionary>?
        guard let sub = createSub(nil, ch, &subbedRaw, 0, nil)?.takeRetainedValue() else { return }

        self.createSamples = createSamples
        self.createDelta = createDelta
        self.getName = getName
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
        self.iterate = iterate
        self.subscription = sub
        self.subbed = subbedRaw?.takeRetainedValue() ?? ch
        isAvailable = true
    }

    /// A fresh residency-weighted reading, or nil while unavailable or before the first delta is
    /// available (the first call just primes the baseline sample).
    func sample() -> Reading? {
        guard isAvailable, let createSamples, let createDelta, let subbed else { return nil }
        guard let now = createSamples(subscription, subbed, nil)?.takeRetainedValue() else { return nil }
        defer { prevSample = now }
        guard let prev = prevSample,
              let delta = createDelta(prev, now, nil)?.takeRetainedValue() else { return nil }
        return compute(delta: delta)
    }

    /// Drop the baseline so the next sample() re-primes (returns nil) instead of diffing against a
    /// stale sample. CPUReader stops sampling while the popover is closed, so without this the first
    /// reading after a reopen would be the residency-weighted average over the whole closed interval
    /// (possibly minutes) rather than the last second. Called from CPUReader.setPanelOpen(true).
    func resetBaseline() { prevSample = nil }

    private func compute(delta: CFDictionary) -> Reading? {
        guard let iterate, let getName, let stateCount, let stateName, let stateResidency else { return nil }

        var effWeighted = 0.0, effActive = 0.0
        var perfWeighted = 0.0, perfActive = 0.0
        let eTable = self.eTable, pTable = self.pTable

        iterate(delta, { ch in
            let name = getName(ch)?.takeUnretainedValue() as String? ?? ""
            // Per-cluster channels that track IDLE are the "*CPU" ones; skip the "*CPM" complex
            // variants (which report IDLE = 0 and a different distribution).
            let isEff = name.hasPrefix("ECPU")
            let isPerf = name.hasPrefix("PCPU")
            guard isEff || isPerf else { return 0 }
            let table = isEff ? eTable : pTable
            // max(0,) because this is a private symbol dlsym'd out of libIOReport, declared in no
            // header, and it returns a SIGNED Int32 — which is how a C API says "I can fail". Handing
            // a negative straight to `0..<count` fails Range's lowerBound <= upperBound precondition,
            // and that precondition is a trap: the app dies rather than skipping the channel. The
            // whole file is already written on the premise that this interface may withdraw at any
            // macOS release — every symbol is optional and every miss degrades to nil — so accepting
            // its return value unexamined was the one place that premise was not honoured.
            let count = max(0, stateCount(ch))
            for i in 0..<count {
                let sn = stateName(ch, i)?.takeUnretainedValue() as String? ?? ""
                guard let idx = Self.dvfsIndex(sn), idx < table.count else { continue }  // skips IDLE/OFF/DOWN
                let r = Double(stateResidency(ch, i))
                if isEff { effWeighted += r * table[idx]; effActive += r }
                else     { perfWeighted += r * table[idx]; perfActive += r }
            }
            return 0
        })

        let eff = effActive > 0 ? effWeighted / effActive : 0
        let perf = perfActive > 0 ? perfWeighted / perfActive : 0
        let totalActive = effActive + perfActive
        let all = totalActive > 0 ? (effWeighted + perfWeighted) / totalActive : 0
        return Reading(allMHz: all, efficiencyMHz: eff, performanceMHz: perf)
    }

    /// DVFS state names look like "V<n>P<m>"; n is the index into the voltage-states table. Non-DVFS
    /// states ("IDLE", "OFF", "DOWN") don't start with a "V<digit>" and return nil, so they're
    /// excluded from the active-frequency average.
    private static func dvfsIndex(_ name: String) -> Int? {
        guard name.hasPrefix("V"), let second = name.dropFirst().first, second.isNumber else { return nil }
        var digits = ""
        for c in name.dropFirst() {
            if c.isNumber { digits.append(c) } else { break }
        }
        return Int(digits)
    }

    /// The pmgr node's voltage-states table for a cluster: 8-byte (rawPeriod, voltage) entries,
    /// little-endian; MHz = 65_536_000 / rawPeriod. Zero-period entries are dropped.
    private static func readVoltageStates(_ key: String) -> [Double] {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard entry != 0 else { return [] }
        defer { IOObjectRelease(entry) }
        guard let cf = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let data = cf as? Data else { return [] }
        var freqs: [Double] = []
        data.withUnsafeBytes { raw in
            let u = raw.bindMemory(to: UInt32.self)
            var i = 0
            while (2 * i) < u.count {
                let period = u[2 * i]
                if period != 0 { freqs.append(65_536_000.0 / Double(period)) }
                i += 1
            }
        }
        return freqs
    }
}
