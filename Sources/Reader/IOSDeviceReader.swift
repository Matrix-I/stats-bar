// IOSDeviceReader.swift — reads iPhone/iPad battery health over USB by shelling out to
// libimobiledevice (idevice_id / ideviceinfo / idevicediagnostics), same approach as
// cocobat.py --ios. Command-line plumbing (locating tools, running with a timeout) lives in
// DeviceTool.

import Foundation
import Combine

@MainActor
final class IOSDeviceReader: ObservableObject {
    @Published var devices: [IOSDeviceInfo] = []
    @Published var toolsMissing = false
    @Published var statusMessage: String?

    /// Only accessed/mutated on the main thread — refresh() is always called from main (button, onAppear, timer).
    private var isBusy = false
    private lazy var poll = PollingTimer { [weak self] in self?.tick() }

    /// Popover visibility, driven by BatteryDetailView (the only view that shows iPhone data). It and
    /// the iPhone menu-bar glyph are what hold the reader at its full ~1 Hz cadence. A connected phone
    /// nobody is watching still refreshes — to feed the hot-battery alerter — but only every
    /// `alerterInterval`, and an idle reader drops to `keepWarmInterval`. See tick(). Main-thread only.
    private var panelOpen = false
    /// Cadence gates use the monotonic clock (DispatchTime / mach uptime), never Date(), so a
    /// wall-clock / NTP step backwards can't wedge a cadence into never firing. nil = never refreshed
    /// (so the gate reads as elapsed). Main-thread only.
    private var lastRefreshAt: DispatchTime?
    /// When the last FULL (heavy diagnostics-relay) read ran. While the glyph is shown but the popover
    /// is closed, most ticks do the cheap light read (charge % only) and only every `alerterInterval`
    /// falls back to a full read — to refresh health and feed the alerter. Separate from lastRefreshAt,
    /// which gates the off-screen cadence. Monotonic, main-thread only.
    private var lastFullRefreshAt: DispatchTime?
    /// Refresh cadence when a phone is connected but off-screen (popover closed, glyph off): frequent
    /// enough for the thermal nudge (battery temperature drifts slowly, and iOS pauses charging when
    /// hot on its own), but not the every-second libimobiledevice fork storm that full 1 Hz would be.
    private static let alerterInterval: TimeInterval = 5
    /// Refresh cadence when nothing is connected and nobody is watching — just often enough to notice
    /// a plug-in promptly.
    private static let keepWarmInterval: TimeInterval = 10

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
    /// 3 s to disappear once it drops out of USB enumeration entirely (usually a real unplug); the
    /// default 30 s to ride out a device that is still enumerated but unreadable — locked, or another
    /// app holding the lockdown session, which tends to recover on its own.
    private var presence = DevicePresenceCache<IOSDeviceInfo, String>(graceGone: 3)

    init() {
        refresh()
        // MenuBarExtra(.window) builds the view once and just shows/hides it afterward — .onAppear
        // doesn't refire on every menu open, so a dedicated timer is needed to pick up plug/unplug events.
        // Poll every second like the Mac reader. Each tick shells out to libimobiledevice (a few
        // subprocesses + USB round-trips), but refresh()'s isBusy guard drops any tick that lands
        // while the previous read is still running, so a slow cycle just lowers the effective rate.
        poll.schedule(every: 1)
    }

    /// Called by BatteryDetailView's visibility reporter. We deliberately do NOT force a read on open
    /// (a slow libimobiledevice read landing mid-animation would snap it — see the note in
    /// BatteryDetailView); the next fast tick, within ~1 s, refreshes, and the warm cache shows meanwhile.
    func setPanelOpen(_ open: Bool) { panelOpen = open }

    /// The 1 Hz timer's handler. Picks the effective cadence from who's actually looking:
    ///  • popover open, or the iPhone menu-bar glyph on → full 1 Hz (the data is on screen);
    ///  • otherwise a connected phone → every `alerterInterval`, enough to keep TemperatureAlerter
    ///    (the hot-battery nudge, driven by publish()) responsive without forking libimobiledevice
    ///    every second for something off-screen;
    ///  • nothing connected and nobody watching → `keepWarmInterval`, just to catch a plug-in.
    /// Dropping a connected-but-unwatched phone from 1 Hz to `alerterInterval` is the big idle-cost win
    /// (see doRefresh — each refresh forks several libimobiledevice tools).
    private func tick() {
        let watched = panelOpen || UserDefaults.standard.bool(forKey: "showIPhoneMenuBar")
        // Off screen → a relaxed cadence, always a full read (there's no glyph to keep live cheaply):
        // a connected phone every alerterInterval (to feed the hot-battery alerter), nothing connected
        // every keepWarmInterval (just to notice a plug-in).
        if !watched {
            let minInterval = devices.isEmpty ? Self.keepWarmInterval : Self.alerterInterval
            guard elapsed(since: lastRefreshAt, atLeast: minInterval) else { return }
            let now = DispatchTime.now()
            lastRefreshAt = now
            lastFullRefreshAt = now
            refresh(full: true)
            return
        }
        // On screen, so refresh every tick. The popover shows full health, so it always does the heavy
        // full read; the menu-bar glyph alone needs only charge % + charging, so between full reads it
        // does the light battery-domain read (see doRefresh), falling back to a full read every
        // alerterInterval to refresh health and feed the alerter. The full-read gate uses the monotonic
        // clock (see elapsed), so an NTP/clock step can't wedge it — and the light read runs every tick
        // regardless, so the visible glyph never stalls.
        let now = DispatchTime.now()
        lastRefreshAt = now
        let full = panelOpen || elapsed(since: lastFullRefreshAt, atLeast: Self.alerterInterval)
        if full { lastFullRefreshAt = now }
        refresh(full: full)
    }

    /// Monotonic elapsed-time gate: true when `mark` is nil (never yet) or at least `seconds` of mach
    /// uptime have passed since it. DispatchTime never runs backwards, so a wall-clock / NTP step can't
    /// stall a cadence the way Date() would.
    private func elapsed(since mark: DispatchTime?, atLeast seconds: TimeInterval) -> Bool {
        guard let mark else { return true }
        return Double(DispatchTime.now().uptimeNanoseconds - mark.uptimeNanoseconds) / 1_000_000_000 >= seconds
    }

    /// `full: false` does the cheap glyph-only pass (enumerate + a light battery-domain charge read),
    /// used between full reads while only the menu-bar glyph is shown. The default is a full read, so
    /// init, the Refresh button, and popover-open all get the complete health readout.
    func refresh(full: Bool = true) {
        guard !isBusy else { return }
        isBusy = true
        // Inherits the main actor, so `publish` lands back here with no extra hop; the await only
        // suspends this task while the worker queue does the blocking probes.
        let worker = self.worker
        Task { [weak self] in
            let res = await worker.refresh(full: full)
            self?.publish(devices: res.devices, toolsMissing: res.toolsMissing, status: res.status)
        }
    }

    private func publish(devices fresh: [IOSDeviceInfo], toolsMissing: Bool, status: String?) {
        self.isBusy = false

        // Runs after whichever branch below finalizes self.devices, so the alerter always sees
        // the final list (including the empty cases, which clear its per-device state).
        defer { self.alerter.check(self.devices) }

        if toolsMissing {
            self.toolsMissing = true
            self.devices = []
            self.statusMessage = nil
            return
        }
        self.toolsMissing = false

        // Each fresh read is one of four kinds, which collapse to three for the cache:
        //  • full read (unlocked)      → .good: shown as-is, becomes the new cached baseline;
        //  • light read (isLightRead)  → .partial: glyph-only pass, live charge %, no health read;
        //  • locked read (isLocked)    → .partial too — live charge only, so the last-known health is
        //                                grafted from cache and stays on screen indefinitely (health
        //                                barely changes; timestamped in the UI). The two differ only in
        //                                whether the row shows a lock badge, never a hard error;
        //  • hard failure (errorMessage) → .failed: untrusted / handshake dropped, so ride out on
        //                                *this* device's own cached data, then surface the error.
        let resolved = presence.resolve(
            fresh, now: Date(), id: \.id,
            kind: { dev in
                if dev.errorMessage == nil, !dev.isLocked, !dev.isLightRead { return .good }
                if dev.isLocked || dev.isLightRead { return .partial }
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
                // Graft the static health figures; leave currentCapacity/amperage/temp/voltage unset so
                // charge stays live (a locked row's lockedChargePercent, a light read's stateOfCharge)
                // and no stale dynamic values are shown.
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
    func refresh(full: Bool) async -> RefreshResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.doRefresh(full: full)) }
        }
    }

    private func doRefresh(full: Bool) -> RefreshResult {
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

            if !full, let cached = infoCache[udid],
               let batt = readBatteryDomain(ideviceInfoPath, udid: udid, network: network) {
                dev.name = cached.name
                dev.model = cached.model
                dev.iosVersion = cached.iosVersion
                dev.stateOfCharge = batt.pct
                dev.isCharging = batt.isCharging
                dev.externalConnected = batt.external
                dev.fullyCharged = batt.full
                dev.isLightRead = true
                results.append(dev)
                continue
            }

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

    private func transportArgs(_ network: Bool) -> [String] { network ? ["-n"] : [] }

    private func infoValue(_ path: String, udid: String, key: String, network: Bool) -> String? {
        guard let data = DeviceTool.run(path, transportArgs(network) + ["-u", udid, "-k", key]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func listOne(_ path: String, _ flag: String) -> Set<String> {
        guard let data = DeviceTool.run(path, [flag]),
              let s = String(data: data, encoding: .utf8) else { return [] }
        return Set(s.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty })
    }

    private func listDevices(_ path: String) -> [(udid: String, network: Bool)] {
        let maxAttempts = sawDeviceLastCycle ? 5 : 1
        for attempt in 0..<maxAttempts {
            let usb = listOne(path, "-l")
            let net = listOne(path, "-n")
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
        for attempt in 0..<3 {
            for cls in ["AppleSmartBattery", "AppleARMPMUCharger"] {
                if let raw = DeviceTool.run(path, transportArgs(network) + ["-u", udid, "ioregentry", cls]),
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
