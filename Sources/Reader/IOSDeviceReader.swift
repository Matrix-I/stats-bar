// IOSDeviceReader.swift — reads iPhone/iPad battery health by shelling out to libimobiledevice
// (idevice_id / ideviceinfo / idevicediagnostics), same approach as cocobat.py --ios. Command-line
// plumbing (locating tools, running with a timeout) lives in DeviceTool.
//
// Over USB *or* over Wi-Fi sync: every probe below takes a transport flag (see transportArgs), and a
// device reached only over the network is surfaced rather than dropped. Worth stating because the header
// claimed USB-only for a long time while the whole `-n` path sat underneath it, and a Wi-Fi read is the
// slower, more failure-prone one — which is the case most of the timing decisions here are sized for.

import Foundation
import Combine

@MainActor
final class IOSDeviceReader: ObservableObject {
    @Published var devices: [IOSDeviceInfo] = []
    @Published var toolsMissing = false
    @Published var statusMessage: String?

    /// Only accessed/mutated on the main thread — refresh() is always called from main (button, popover
    /// visibility, timer).
    private var isBusy = false
    private lazy var poll = PollingTimer { [weak self] in self?.tick() }

    /// Popover visibility, driven by BatteryDetailView (the only view that shows iPhone data). Together
    /// with the iPhone menu-bar glyph it decides how often we look — see `watcher`. Main-thread only.
    private var panelOpen = false

    /// Which interval applies to which audience, and how long a device may be missing before it is
    /// dropped. Lives in Sources/Core (DeviceReadCadence) with the numbers as its defaults, so the reader
    /// and its tests read one source instead of two copies that drift. Constructed with no arguments on
    /// purpose — see that type's header.
    private static let cadence = DeviceReadCadence()

    /// Who can see the readings right now. Both the read cadence and the presence cache's ride-out window
    /// are derived from this.
    private var watcher: DeviceReadCadence.Watcher {
        if panelOpen { return .popover }
        return UserDefaults.standard.bool(forKey: "showIPhoneMenuBar") ? .glyph : .nobody
    }

    /// Point the timer at the interval the current audience deserves. `PollingTimer.schedule` no-ops when
    /// the interval is unchanged, so this is safe to call on every publish and every visibility change.
    ///
    /// The timer carrying the cadence — rather than a fixed 1 Hz timer whose ticks get gated on elapsed
    /// time — is the whole design, and it is not a matter of taste. With two rates, a read starting a few
    /// milliseconds after a tick leaves the next tick fractionally short of the interval, so it skips: a
    /// 2 s interval measurably read every 3 s, and the popover's 1 s interval every 1-2 s. One rate cannot
    /// beat against itself. BatteryReader.applyCadence has done it this way all along.
    private func applyCadence() {
        poll.schedule(every: Self.cadence.interval(watcher, deviceAttached: !devices.isEmpty))
    }

    /// Runs the enumeration off the main thread and owns the caches that outlive a single refresh
    /// (device identities, whether the last cycle saw anything). See the type for why it is a
    /// queue-confined class rather than an actor.
    private let worker = IOSDeviceWorker()

    /// Warns (macOS notification) when a device's battery runs hot. Touched only on the main thread,
    /// inside publish, so its threshold-crossing state stays single-threaded.
    private let alerter = TemperatureAlerter()

    /// Which device to show as read, which to show with cached health grafted on, and which to keep
    /// showing while its reads fail — plus the cache of last-good reads all of that rests on. Lives in
    /// Sources/Core (DevicePresenceCache) so it can be unit-tested: this type can't be, since it is an
    /// ObservableObject that shells out to libimobiledevice. Only touched on the main thread, inside
    /// publish, so its per-device state stays single-threaded.
    ///
    /// `graceGone` — how long a device may be missing before it disappears — is re-derived on every
    /// publish from the interval actually in force, so the value passed here only covers the very first
    /// read. It used to be a flat 3 s, which could never fire on the two cadences that tick every 5 s and
    /// 10 s: the previous sighting was already older than the window by the time the next tick
    /// enumerated, so one blip dropped the device outright. See DeviceReadCadence.graceGone.
    ///
    /// `graceUnreadable` keeps its default 30 s: a device that is still enumerated but unreadable —
    /// locked, or another app holding the lockdown session — tends to recover on its own.
    private var presence = DevicePresenceCache<IOSDeviceInfo, String>(
        graceGone: IOSDeviceReader.cadence.graceGone(.popover, deviceAttached: false)
    )

    init() {
        refresh()
        // MenuBarExtra(.window) builds the view once and just shows/hides it afterward — .onAppear
        // doesn't refire on every menu open, so a dedicated timer is needed to pick up plug/unplug events.
        applyCadence()
    }

    /// Called by BatteryDetailView's visibility reporter. Forces a read on the opening edge, which is what
    /// BatteryReader.setPanelOpen has always done — the iPhone reader was the odd one out, and that
    /// asymmetry is why the Mac card was complete the moment the popover appeared and the iPhone card was
    /// not.
    ///
    /// This used to be a bare assignment, on the argument that a slow libimobiledevice read landing
    /// mid-animation would snap the popover. That argument died with the light read: every read now
    /// produces the same set of fields, so one landing late changes numbers in place instead of adding
    /// four rows and growing the card mid-flight.
    func setPanelOpen(_ open: Bool) {
        guard open != panelOpen else { return }
        panelOpen = open
        applyCadence()
        if open { refresh() }
    }

    /// The timer's handler. The timer already runs at the right interval (see applyCadence), so every tick
    /// is a read; `refresh`'s isBusy guard is what keeps a slow cycle from piling up.
    private func tick() { refresh() }

    /// One read: enumerate, then identity and the battery registry for every device found. There is no
    /// cheap variant any more — see doRefresh for why the glyph-only pass was removed.
    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        // Inherits the main actor, so `publish` lands back here with no extra hop; the await only
        // suspends this task while the worker queue does the blocking probes.
        let worker = self.worker
        Task { [weak self] in
            let res = await worker.refresh()
            self?.publish(devices: res.devices, toolsMissing: res.toolsMissing, status: res.status)
        }
    }

    private func publish(devices fresh: [IOSDeviceInfo], toolsMissing: Bool, status: String?) {
        self.isBusy = false

        // Runs after whichever branch below finalizes self.devices, so the alerter always sees
        // the final list (including the empty cases, which clear its per-device state).
        defer { self.alerter.check(self.devices) }

        // Same reason, for the cadence: whether anything is attached is one of its inputs, so it has to be
        // re-read once this publish has settled the list. A phone appearing tightens the interval from
        // idle to off-screen; the last one leaving relaxes it again.
        defer { self.applyCadence() }

        if toolsMissing {
            self.toolsMissing = true
            self.devices = []
            self.statusMessage = nil
            return
        }
        self.toolsMissing = false

        // The ride-out window has to track how often we actually look, so it is set here rather than once
        // at init: a window shorter than the polling interval can never fire, because the previous
        // sighting is already older than it by the time the next tick enumerates. `deviceAttached` reads
        // the list as it stands BEFORE this publish rewrites it — that is the cadence the sighting was
        // recorded under, which is the interval the window has to cover. See DeviceReadCadence.graceGone.
        presence.graceGone = Self.cadence.graceGone(watcher, deviceAttached: !self.devices.isEmpty)

        // Each fresh read is one of three kinds:
        //  • unlocked read (no error)    → .good: shown as-is, becomes the new cached baseline;
        //  • locked read (isLocked)      → .partial: the diagnostics registry is refused at the lock
        //                                  screen, but the lockdown battery domain still answers, so
        //                                  charge stays live and the last-known health is grafted from
        //                                  cache and stays on screen indefinitely (health barely changes;
        //                                  timestamped in the UI). Never a hard error;
        //  • hard failure (errorMessage) → .failed: untrusted / handshake dropped, so ride out on
        //                                  *this* device's own cached data, then surface the error.
        let resolved = presence.resolve(
            fresh, now: Date(), id: \.id,
            kind: { dev in
                if dev.errorMessage == nil, !dev.isLocked { return .good }
                if dev.isLocked { return .partial }
                return .failed
            },
            capturedAt: \.capturedAt
        )

        // Nothing at all to show. Only reachable from an empty enumeration with nothing recent enough to
        // ride out: any non-empty enumeration resolves to one row per device.
        if resolved.isEmpty {
            self.devices = []
            self.statusMessage = status
                ?? "No iPhone/iPad found over USB or Wi-Fi.\nPlug in the cable (unlock + tap Trust), or turn on “Sync over Wi-Fi” in Finder."
            return
        }

        self.devices = resolved.map { row in
            switch row {
            case .fresh(let dev):
                return dev
            case .grafted(let dev, let prev):
                // A locked device. Graft the static health figures; leave currentCapacity/amperage/temp/
                // voltage unset so charge stays live (lockedChargePercent) and no stale dynamic values
                // are shown. The staleness here is genuinely unbounded — the registry stays refused for as
                // long as the phone stays locked — which is why the card labels this row rather than
                // presenting it as a live reading.
                var m = dev
                m.maxCapacity = prev.maxCapacity
                m.nominalChargeCapacity = prev.nominalChargeCapacity
                m.designCapacity = prev.designCapacity
                m.cycleCount = prev.cycleCount
                m.serial = prev.serial
                m.capturedAt = prev.capturedAt   // when those health figures were actually read
                return m
            case .cachedStale(let prev):
                var s = prev
                s.isStale = true
                return s
            }
        }
        self.statusMessage = nil
    }
}

/// Owns the libimobiledevice enumeration and the caches that survive between refreshes.
///
/// Deliberately NOT an actor: every probe below blocks its thread — DeviceTool.run waits on a child
/// process for up to the tool timeout, and the retry loops sleep between attempts — and a worst-case
/// pass can sit there for tens of seconds. An actor runs on Swift's cooperative thread pool, which is
/// only as wide as the core count and whose threads must never block; parking one there starves every
/// other async task in the process. A dedicated serial queue gives the same mutual exclusion (all
/// state below is touched only from `queue`, which is what makes the @unchecked Sendable sound) on a
/// thread we own and are free to block.
private final class IOSDeviceWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "StatsBar.IOSDeviceWorker", qos: .userInitiated)

    private var sawDeviceLastCycle = true
    private var infoCache: [String: (name: String, model: String, iosVersion: String)] = [:]

    struct RefreshResult: Sendable {
        let devices: [IOSDeviceInfo]
        let toolsMissing: Bool
        let status: String?
    }

    /// Runs one enumeration on the worker queue. The caller's task suspends — it does not block — so
    /// the main actor stays responsive while the probes run.
    func refresh() async -> RefreshResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.doRefresh()) }
        }
    }

    /// One read shape, deliberately.
    ///
    /// There used to be a second, cheap pass here — enumerate plus a lockdown battery-domain charge read —
    /// taken between full reads while only the menu-bar glyph was shown. It cost the popover its
    /// correctness: the battery domain carries seven keys and none of them is Temperature, Voltage or
    /// Amperage, so a row published by the cheap pass had those fields nil and the card rendered four
    /// fewer rows. Opening the popover therefore always landed on the short shape first and grew ~1.1 s
    /// later, once the next tick's full read published. Grafting the missing values from cache was the
    /// obvious alternative and the wrong one: publish() is the only writer of `devices` and refresh()
    /// bails while a read is in flight, so a long read freezes the last published row — harmless while
    /// those fields are nil, actively misleading once they are filled with borrowed numbers.
    ///
    /// What paid for the cheap pass was a 1 Hz cadence that iOS cannot honour anyway: it refreshes the
    /// AppleSmartBattery snapshot every 7-20 seconds (measured), so most of those reads re-fetched an
    /// identical snapshot. Reading fully at DeviceReadCadence's glyph interval instead costs fewer
    /// subprocesses than the split did and leaves one row shape for every audience.
    private func doRefresh() -> RefreshResult {
        guard let ideviceIdPath = DeviceTool.path("idevice_id"),
              let ideviceInfoPath = DeviceTool.path("ideviceinfo"),
              let diagnosticsPath = DeviceTool.path("idevicediagnostics") else {
            return RefreshResult(devices: [], toolsMissing: true, status: nil)
        }

        let devicesList = listDevices(ideviceIdPath)
        guard !devicesList.isEmpty else {
            infoCache.removeAll()
            return RefreshResult(devices: [], toolsMissing: false,
                                 status: "No iPhone/iPad found over USB or Wi-Fi.\nPlug in the cable (unlock + tap Trust), or turn on “Sync over Wi-Fi” in Finder.")
        }
        let present = Set(devicesList.map(\.udid))
        infoCache = infoCache.filter { present.contains($0.key) }

        var results: [IOSDeviceInfo] = []
        for (udid, network) in devicesList {
            var dev = IOSDeviceInfo(id: udid)
            dev.isNetwork = network

            let trusted: Bool
            if let cached = infoCache[udid] {
                dev.name = cached.name
                dev.model = cached.model
                dev.iosVersion = cached.iosVersion
                trusted = true
            } else if let batch = readDeviceInfoPlist(ideviceInfoPath, udid: udid, network: network) {
                dev.name = batch.name
                dev.model = batch.model
                dev.iosVersion = batch.iosVersion
                trusted = true
                if !batch.model.isEmpty, !batch.iosVersion.isEmpty {
                    infoCache[udid] = batch
                }
            } else {
                let named = infoValue(ideviceInfoPath, udid: udid, key: "DeviceName", network: network)
                let model = infoValue(ideviceInfoPath, udid: udid, key: "ProductType", network: network) ?? ""
                let version = infoValue(ideviceInfoPath, udid: udid, key: "ProductVersion", network: network) ?? ""
                dev.name = named ?? udid
                dev.model = model
                dev.iosVersion = version
                trusted = named != nil
                if let named, !model.isEmpty, !version.isEmpty { infoCache[udid] = (named, model, version) }
            }

            if let reg = readBatteryRegistry(diagnosticsPath, udid: udid, network: network) {
                dev.serial = reg["Serial"] as? String ?? ""
                dev.designCapacity = intOrNil(reg["DesignCapacity"])
                dev.maxCapacity = intOrNil(reg["AppleRawMaxCapacity"]) ?? intOrNil(reg["NominalChargeCapacity"])
                dev.nominalChargeCapacity = intOrNil(reg["NominalChargeCapacity"])
                dev.currentCapacity = intOrNil(reg["AppleRawCurrentCapacity"])
                if let relMax = intOrNil(reg["MaxCapacity"]), relMax > 0,
                   let relCur = intOrNil(reg["CurrentCapacity"]) {
                    dev.stateOfCharge = min(100, Double(relCur) / Double(relMax) * 100)
                }
                dev.cycleCount = intOrNil(reg["CycleCount"])
                // Signed for the same reason as Amperage below — see BatteryReader. Reading a
                // sub-zero temperature unsigned would also trip TemperatureAlerter's hot-battery
                // warning, since the bogus value is far above the threshold.
                if let t = signedIntOrNil(reg["Temperature"]) { dev.temperatureC = Double(t) / 100.0 }
                if let v = intOrNil(reg["Voltage"]) { dev.voltageV = Double(v) / 1000.0 }
                if let a = signedIntOrNil(reg["Amperage"]) { dev.amperageA = Double(a) / 1000.0 }
                dev.isCharging = reg["IsCharging"] as? Bool ?? false
                dev.externalConnected = reg["ExternalConnected"] as? Bool ?? false
                dev.fullyCharged = reg["FullyCharged"] as? Bool ?? false
                dev.capturedAt = Date()
            } else if trusted {
                dev.isLocked = true
                if let batt = readBatteryDomain(ideviceInfoPath, udid: udid, network: network) {
                    dev.lockedChargePercent = batt.pct
                    dev.isCharging = batt.isCharging
                    dev.externalConnected = batt.external
                    dev.fullyCharged = batt.full
                }
            } else {
                dev.errorMessage = "Couldn't reach the device — unlock it and tap Trust."
            }

            results.append(dev)
        }

        return RefreshResult(devices: results, toolsMissing: false, status: nil)
    }

    /// A wall-clock deadline for one multi-attempt probe.
    ///
    /// Both retry loops below used to bound each CALL and nothing else, which is not a bound at all:
    /// readBatteryRegistry's 3 attempts x 2 registry classes could sit for 3 x 2 x DeviceTool.toolTimeout
    /// plus its sleeps — 24.6 s, or 36.6 s once DeviceTool escalates to SIGKILL on a child that ignores
    /// SIGTERM — and listDevices' 5 attempts x 2 calls for 41.6 s. That matters beyond the wasted time:
    /// publish() is the only writer of `devices` and refresh() bails while a read is in flight, so for the
    /// whole of that the card is frozen on its last row AND the Refresh button is dead, because it calls
    /// the same refresh(). DeviceTool's comment names the trigger — a tool "blocked in a usbmux syscall on
    /// a locked device" — so this is the ordinary locked-phone path, not an exotic one.
    ///
    /// Retries keep their point: a probe whose calls fail fast (the common transient case) still gets all
    /// its attempts well inside the budget. What is gone is the pathological tail.
    private struct Budget {
        private let end: DispatchTime
        init(_ seconds: TimeInterval) { end = DispatchTime.now() + seconds }
        /// Seconds left, never negative — DispatchTime's nanoseconds are unsigned, so the comparison has
        /// to come first: `end - now` on an overrun budget would trap rather than go negative.
        var remaining: TimeInterval {
            let now = DispatchTime.now()
            guard now < end else { return 0 }
            return Double(end.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
        }
        /// What to pass a single call: its own timeout, or the rest of the budget if that is shorter.
        var callTimeout: TimeInterval { min(DeviceTool.toolTimeout, remaining) }
        /// Whether there is enough left to be worth another attempt. A call given a sliver of a second
        /// would be killed before the device could answer, so spending the sliver buys nothing.
        var allowsAnotherCall: Bool { remaining > 0.25 }
    }

    /// Total wall-clock budget for enumerating the bus. Generous next to the ~9 ms `idevice_id` normally
    /// takes; it exists only to cap the case where usbmuxd itself is wedged.
    private static let enumerateBudget: TimeInterval = 6

    /// Total wall-clock budget for one device's registry read. Wide enough that both registry classes get
    /// a full DeviceTool.toolTimeout on the first attempt — if neither answers in 4 s the device is not
    /// answering — while capping the retry tail at one round rather than three.
    private static let registryBudget: TimeInterval = 8

    private func transportArgs(_ network: Bool) -> [String] { network ? ["-n"] : [] }

    private func infoValue(_ path: String, udid: String, key: String, network: Bool) -> String? {
        guard let data = DeviceTool.run(path, transportArgs(network) + ["-u", udid, "-k", key]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func listOne(_ path: String, _ flag: String, timeout: TimeInterval) -> Set<String> {
        guard let data = DeviceTool.run(path, [flag], timeout: timeout),
              let s = String(data: data, encoding: .utf8) else { return [] }
        return Set(s.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty })
    }

    private func listDevices(_ path: String) -> [(udid: String, network: Bool)] {
        let maxAttempts = sawDeviceLastCycle ? 5 : 1
        let budget = Budget(Self.enumerateBudget)
        for attempt in 0..<maxAttempts {
            guard budget.allowsAnotherCall else { break }
            let usb = listOne(path, "-l", timeout: budget.callTimeout)
            let net = listOne(path, "-n", timeout: budget.callTimeout)
            if !usb.isEmpty || !net.isEmpty {
                sawDeviceLastCycle = true
                var out = usb.sorted().map { (udid: $0, network: false) }
                out += net.subtracting(usb).sorted().map { (udid: $0, network: true) }
                return out
            }
            if attempt < maxAttempts - 1 { Thread.sleep(forTimeInterval: 0.4) }
        }
        sawDeviceLastCycle = false
        return []
    }

    private func readBatteryDomain(_ path: String, udid: String, network: Bool)
        -> (pct: Double, isCharging: Bool, external: Bool, full: Bool)? {
        guard let data = DeviceTool.run(path, transportArgs(network) + ["-u", udid, "-q", "com.apple.mobile.battery", "-x"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let pct = intOrNil(plist["BatteryCurrentCapacity"]) else { return nil }
        return (Double(pct),
                plist["BatteryIsCharging"] as? Bool ?? false,
                plist["ExternalConnected"] as? Bool ?? false,
                plist["FullyCharged"] as? Bool ?? false)
    }

    private func readBatteryRegistry(_ path: String, udid: String, network: Bool) -> [String: Any]? {
        let budget = Budget(Self.registryBudget)
        for attempt in 0..<3 {
            for cls in ["AppleSmartBattery", "AppleARMPMUCharger"] {
                guard budget.allowsAnotherCall else { return nil }
                if let raw = DeviceTool.run(path, transportArgs(network) + ["-u", udid, "ioregentry", cls],
                                            timeout: budget.callTimeout),
                   let plist = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil) as? [String: Any],
                   let reg = plist["IORegistry"] as? [String: Any],
                   reg["AppleRawMaxCapacity"] != nil || reg["NominalChargeCapacity"] != nil
                       || reg["DesignCapacity"] != nil || reg["CycleCount"] != nil {
                    return reg
                }
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.3) }
        }
        return nil
    }

    private func readDeviceInfoPlist(_ path: String, udid: String, network: Bool) -> (name: String, model: String, iosVersion: String)? {
        guard let data = DeviceTool.run(path, transportArgs(network) + ["-u", udid, "-x"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let name = plist["DeviceName"] as? String, !name.isEmpty else { return nil }
        let model = (plist["ProductType"] as? String) ?? ""
        let version = (plist["ProductVersion"] as? String) ?? ""
        return (name, model, version)
    }
}
