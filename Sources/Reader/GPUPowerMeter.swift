// GPUPowerMeter.swift — whole-GPU power draw from the private IOReport framework, the same
// undocumented surface CPUFrequency reads and with the same fail-soft contract: if the library, a
// symbol, the group or the channel is missing, `isAvailable` stays false, `sample()` returns nil and
// the panel hides the row rather than printing a fabricated zero.
//
// It subscribes once to the "Energy Model" group and diffs its cumulative counters, because the SoC
// publishes ENERGY, not power — watts are a quotient this app forms (GPUEnergy.watts, where the unit
// scaling is pinned by measurement).
//
// Which channel carries the energy was decided by reading them rather than by picking a likely name.
// On this M1 Pro the group lists ~130 channels and almost all of them read exactly 0, including the
// plausibly named "GPU0", "CPU Energy" and "DRAM0"; the one that moves is "GPU Energy", which went
// from 293,806,250 nJ over an idle 2 s to 24,239,942,710 nJ over 3 s of saturating Metal compute.
// "GPU0" is kept as a fallback for a SoC that populates it instead, and the two are never added
// together — on a machine that populated both they would be the same joules counted twice.
//
// Subscribing to the whole group rather than a subgroup is deliberate: "Energy Model" has no
// subgroups, so there is no narrower handle to ask for. The cost is one sample of ~130 counters per
// tick, paid only while the popover is open (GPUReader gates it), which is a fraction of what the
// per-core CPU tick sampler already does every second with the popover closed.

import Foundation
import IOKit

final class GPUPowerMeter {
    private(set) var isAvailable = false

    // IOReport function-pointer typedefs. Same reverse-engineered signatures CPUFrequency uses; the
    // two differ only in needing IOReportSimpleGetIntegerValue (a plain counter) here rather than the
    // state-residency trio (a distribution) there.
    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamples = @convention(c) (AnyObject?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetChannelName = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleGetIntegerValue = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias IterateFn = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void

    private var createSamples: CreateSamples?
    private var createDelta: CreateSamplesDelta?
    private var getName: GetChannelName?
    private var simpleValue: SimpleGetIntegerValue?
    private var iterate: IterateFn?

    private var subscription: AnyObject?
    private var subbed: CFMutableDictionary?
    private var prevSample: CFDictionary?
    private var prevAt: DispatchTime?

    /// Preferred first. See the header for why these are tried in order instead of summed.
    private static let energyChannels = ["GPU Energy", "GPU0"]

    init() { setup() }

    private func setup() {
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
              let simpleValue = fn("IOReportSimpleGetIntegerValue", SimpleGetIntegerValue.self),
              let iterate = fn("IOReportIterate", IterateFn.self)
        else { return }

        guard let ch = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        var subbedRaw: Unmanaged<CFMutableDictionary>?
        guard let sub = createSub(nil, ch, &subbedRaw, 0, nil)?.takeRetainedValue() else { return }

        self.createSamples = createSamples
        self.createDelta = createDelta
        self.getName = getName
        self.simpleValue = simpleValue
        self.iterate = iterate
        self.subscription = sub
        self.subbed = subbedRaw?.takeRetainedValue() ?? ch
        isAvailable = true
    }

    /// Average watts over the interval since the previous call, or nil while unavailable and on the
    /// first call after a reset (which only primes the baseline).
    func sample() -> Double? {
        guard isAvailable, let createSamples, let createDelta, let subbed else { return nil }
        let now = DispatchTime.now()
        guard let current = createSamples(subscription, subbed, nil)?.takeRetainedValue() else { return nil }
        defer { prevSample = current; prevAt = now }
        guard let prev = prevSample, let prevAt,
              let delta = createDelta(prev, current, nil)?.takeRetainedValue() else { return nil }
        // uptimeNanoseconds is UInt64 and this app ships -O, not -Ounchecked, so an out-of-order pair
        // would TRAP here rather than wrap. DispatchTime is monotonic and so it should not happen —
        // which is exactly why it is guarded instead of assumed: the cost is one comparison and the
        // failure it prevents is a crash in a background tick.
        guard now.uptimeNanoseconds >= prevAt.uptimeNanoseconds else { return nil }
        let seconds = Double(now.uptimeNanoseconds - prevAt.uptimeNanoseconds) / 1e9
        guard let nanojoules = energyDelta(delta) else { return nil }
        return GPUEnergy.watts(nanojoules: nanojoules, seconds: seconds)
    }

    /// Drop the baseline so the next sample() re-primes instead of diffing against a stale snapshot.
    /// Without it, the first reading after the popover reopens would average the GPU's draw over the
    /// whole time it was closed — possibly hours — and present it as the current wattage.
    func resetBaseline() {
        prevSample = nil
        prevAt = nil
    }

    /// The energy counted in this delta, in nanojoules, from the first of the candidate channels that
    /// the delta actually carries.
    private func energyDelta(_ delta: CFDictionary) -> Int64? {
        guard let iterate, let getName, let simpleValue else { return nil }
        var found: [String: Int64] = [:]
        iterate(delta, { channel in
            guard let name = getName(channel)?.takeUnretainedValue() as String?,
                  Self.energyChannels.contains(name) else { return 0 }
            found[name] = simpleValue(channel, 0)
            return 0
        })
        return Self.energyChannels.compactMap { found[$0] }.first
    }
}
