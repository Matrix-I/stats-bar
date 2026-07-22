// IOSDeviceReader.swift — reads iPhone/iPad battery health over USB by shelling out to
// libimobiledevice (idevice_id / ideviceinfo / idevicediagnostics), same approach as
// cocobat.py --ios. Command-line plumbing (locating tools, running with a timeout) lives in
// DeviceTool.

import Foundation
import Combine

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
    private var lastRefreshAt = Date.distantPast
    /// When the last FULL (heavy diagnostics-relay) read ran. While the glyph is shown but the popover
    /// is closed, most ticks do the cheap light read (charge % only) and only every `alerterInterval`
    /// falls back to a full read — to refresh health and feed the alerter. Separate from lastRefreshAt,
    /// which gates the off-screen cadence. Main-thread only.
    private var lastFullRefreshAt = Date.distantPast
    /// Refresh cadence when a phone is connected but off-screen (popover closed, glyph off): frequent
    /// enough for the thermal nudge (battery temperature drifts slowly, and iOS pauses charging when
    /// hot on its own), but not the every-second libimobiledevice fork storm that full 1 Hz would be.
    private static let alerterInterval: TimeInterval = 5
    /// Refresh cadence when nothing is connected and nobody is watching — just often enough to notice
    /// a plug-in promptly.
    private static let keepWarmInterval: TimeInterval = 10

    /// Whether the previous enumeration found a device. Touched only inside the doRefresh call chain
    /// (listDevices), which the isBusy guard serializes — one doRefresh finishes before the next
    /// starts — so no locking is needed. Gates the retry burst below: it's worth it only when a
    /// device was around last cycle (ride out a transient usbmux drop during a reconnect); when idle
    /// it just wastes forks and sleeps re-confirming "still nothing". Starts true so a device present
    /// at launch is still caught by the burst; self-adjusts after the first cycle.
    private var sawDeviceLastCycle = true

    /// Per-device identity (name / model / iOS version) keyed by UDID. These are constant for a given
    /// device but each costs a separate `ideviceinfo` fork, so read them once on first sight and reuse
    /// them — a steady-state refresh then spends its forks on the battery read, not on re-fetching
    /// constants. Pruned to the currently-enumerated devices each refresh, so a reconnect (or a device
    /// that becomes trusted) reads fresh. Touched only inside the doRefresh chain, which the isBusy
    /// guard serializes (one doRefresh finishes before the next starts), so no locking is needed.
    private var infoCache: [String: (name: String, model: String, iosVersion: String)] = [:]

    /// Warns (macOS notification) when a device's battery runs hot. Touched only on the main thread,
    /// inside publish, so its threshold-crossing state stays single-threaded.
    private let alerter = TemperatureAlerter()

    /// Cache of the most recently read devices (only touched on the main thread, inside publish) —
    /// used to keep showing data when the USB connection drops briefly instead of the device "vanishing".
    private var lastGood: [IOSDeviceInfo] = []
    /// Last time each UDID appeared in a fresh enumeration, so a cache entry is pruned once its
    /// device has been gone longer than staleGraceGone — regardless of whether *other* devices are
    /// still reading. A single global timestamp can't express "device A left but B is fine".
    private var lastSeenAt: [String: Date] = [:]
    /// How long to keep showing the last reading after reads stop succeeding, before the device
    /// disappears. Short when it drops out of USB enumeration entirely (usually a real unplug),
    /// longer when it's still enumerated but the battery read fails (e.g. locked / another app holds
    /// the lockdown session, which tends to recover on its own).
    private static let staleGraceGone: TimeInterval = 3
    private static let staleGraceUnreadable: TimeInterval = 30

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
        // Off screen → a relaxed, clock-gated cadence, always a full read (there's no glyph to keep
        // live cheaply): a connected phone every alerterInterval (to feed the hot-battery alerter),
        // nothing connected every keepWarmInterval (just to notice a plug-in).
        if !watched {
            let minInterval = devices.isEmpty ? Self.keepWarmInterval : Self.alerterInterval
            guard Date().timeIntervalSince(lastRefreshAt) >= minInterval else { return }
            lastRefreshAt = Date()
            lastFullRefreshAt = lastRefreshAt
            refresh(full: true)
            return
        }
        // On screen, so refresh every tick with NO wall-clock dependence — an NTP/clock step backwards
        // can't stall the visible readout. The popover shows full health, so it always does the heavy
        // full read; the menu-bar glyph alone needs only charge % + charging, so between full reads it
        // does the light battery-domain read (see doRefresh), falling back to a full read every
        // alerterInterval to refresh health and feed the alerter.
        lastRefreshAt = Date()
        let full = panelOpen || Date().timeIntervalSince(lastFullRefreshAt) >= Self.alerterInterval
        if full { lastFullRefreshAt = lastRefreshAt }
        refresh(full: full)
    }

    /// `full: false` does the cheap glyph-only pass (enumerate + a light battery-domain charge read),
    /// used between full reads while only the menu-bar glyph is shown. The default is a full read, so
    /// init, the Refresh button, and popover-open all get the complete health readout.
    func refresh(full: Bool = true) {
        guard !isBusy else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.doRefresh(full: full)
        }
    }

    /// libimobiledevice tools default to the USB transport; pass `-n` to reach a device that is only
    /// available over Wi-Fi sync. Every read prefixes its args with this so network devices work.
    private func transportArgs(_ network: Bool) -> [String] { network ? ["-n"] : [] }

    private func infoValue(_ path: String, udid: String, key: String, network: Bool) -> String? {
        guard let data = DeviceTool.run(path, transportArgs(network) + ["-u", udid, "-k", key]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One transport's UDID set — `-l` lists USB devices, `-n` lists network (Wi-Fi sync) devices.
    private func listOne(_ path: String, _ flag: String) -> Set<String> {
        guard let data = DeviceTool.run(path, [flag]),
              let s = String(data: data, encoding: .utf8) else { return [] }
        return Set(s.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty })
    }

    /// Lists connected devices across BOTH transports, retrying a few times since the connection
    /// (usbmux) can drop for a few seconds — especially when the device is locked or another app is
    /// holding the lockdown session. A device that's plugged in over a charge-only cable (or a hub
    /// that carries no data) never shows over USB, yet is still reachable over Wi-Fi when "Sync over
    /// Wi-Fi" is on — so `-n` is enumerated too and those are read over the network transport. USB
    /// wins when a device is reachable both ways: it's faster and always live while plugged in.
    private func listDevices(_ path: String) -> [(udid: String, network: Bool)] {
        // Retry only when a device was present last cycle (ride out a reconnect blip); otherwise a
        // single -l/-n pass. In steady-state idle the burst is pure waste — it never finds anything
        // and the 1 Hz timer re-checks a second later, so a device appearing mid-idle is still picked
        // up promptly without paying 5×(two forks + a 0.4s sleep) every cycle, forever.
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

    /// Reads the lockdown battery domain (com.apple.mobile.battery). Unlike the diagnostics
    /// registry, this is a plain lockdownd value read, not a "started" service, so it keeps working
    /// while the device sits at the passcode lock screen — but it only exposes a coarse 0–100%
    /// charge level and the charging flags, never the mAh / health / cycle-count that live behind
    /// the (unlock-gated) diagnostics relay.
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

    /// Reads the battery IORegistry over the diagnostics relay. The gas-gauge data lives under
    /// different IOKit classes depending on the device/OS: modern iPhones expose it as
    /// `AppleSmartBattery`, but iPhone 7-era hardware on iOS 15 leaves that entry empty (the relay
    /// answers Status=Success with no IORegistry payload) and carries the *same keys* under
    /// `AppleARMPMUCharger` instead. Try both and take whichever actually returns a registry with
    /// battery figures, so an empty `AppleSmartBattery` isn't mistaken for a locked device. Retries
    /// since diagnostics also drops out temporarily. Returns nil only when neither class yields data
    /// — the genuine "relay refused" (locked) case, handled by the caller.
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

    private func doRefresh(full: Bool) {
        guard let ideviceIdPath = DeviceTool.path("idevice_id"),
              let ideviceInfoPath = DeviceTool.path("ideviceinfo"),
              let diagnosticsPath = DeviceTool.path("idevicediagnostics") else {
            publish(devices: [], toolsMissing: true, status: nil)
            return
        }

        let devicesList = listDevices(ideviceIdPath)
        guard !devicesList.isEmpty else {
            infoCache.removeAll()   // nothing on the bus — forget every cached identity
            publish(devices: [], toolsMissing: false,
                    status: "No iPhone/iPad found over USB or Wi-Fi.\nPlug in the cable (unlock + tap Trust), or turn on “Sync over Wi-Fi” in Finder.")
            return
        }
        // Drop identities for devices no longer enumerated (unplugged, or trust changed), so a
        // reconnect re-reads them; keyed on the current enumeration, matching how the reader treats
        // "present" everywhere else.
        let present = Set(devicesList.map(\.udid))
        infoCache = infoCache.filter { present.contains($0.key) }

        var results: [IOSDeviceInfo] = []
        for (udid, network) in devicesList {
            var dev = IOSDeviceInfo(id: udid)
            dev.isNetwork = network

            // Light pass (menu-bar glyph only): the glyph needs just charge % + charging, which the
            // lightweight lockdown battery domain gives in a single fork — so skip the heavy
            // diagnostics-relay ioregentry read here, letting it run only on the periodic full pass
            // (see tick()). Only a device we've already fully read (identity cached) qualifies; a
            // first-sight device falls through to the full read below so it gets its identity and a
            // health baseline. publish() grafts the last-known health onto a light read just like a
            // locked read, and never treats it as a new baseline.
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

            // Identity is constant per device, so read it once and cache it — a steady-state refresh
            // then skips these three ideviceinfo forks. We cache only a successful read (DeviceName
            // non-nil), so a cache hit also means the lockdown handshake completed, i.e. the device is
            // paired/trusted; a miss means we just tried and `named` reflects this cycle's attempt.
            let trusted: Bool
            if let cached = infoCache[udid] {
                dev.name = cached.name
                dev.model = cached.model
                dev.iosVersion = cached.iosVersion
                trusted = true
            } else {
                let named = infoValue(ideviceInfoPath, udid: udid, key: "DeviceName", network: network)
                let model = infoValue(ideviceInfoPath, udid: udid, key: "ProductType", network: network) ?? ""
                let version = infoValue(ideviceInfoPath, udid: udid, key: "ProductVersion", network: network) ?? ""
                dev.name = named ?? udid
                dev.model = model
                dev.iosVersion = version
                trusted = named != nil
                // Cache only a COMPLETE identity: each field is a separate ideviceinfo fork+handshake,
                // so DeviceName can succeed while ProductType/ProductVersion transiently stall on a
                // flaky link. Caching those empties would pin a blank model/iOS version until unplug;
                // requiring all three lets a partial read self-heal on the next tick (as the old
                // per-tick read did). A trusted device always reports all three, so this keeps the
                // optimization in practice and just falls back to per-tick reads otherwise.
                if let named, !model.isEmpty, !version.isEmpty { infoCache[udid] = (named, model, version) }
            }

            if let reg = readBatteryRegistry(diagnosticsPath, udid: udid, network: network) {
                dev.serial = reg["Serial"] as? String ?? ""
                dev.designCapacity = intOrNil(reg["DesignCapacity"])
                dev.maxCapacity = intOrNil(reg["AppleRawMaxCapacity"]) ?? intOrNil(reg["NominalChargeCapacity"])
                dev.nominalChargeCapacity = intOrNil(reg["NominalChargeCapacity"])
                dev.currentCapacity = intOrNil(reg["AppleRawCurrentCapacity"])
                // Calibrated State of Charge iOS shows (the relative CurrentCapacity key, 0–100 with
                // MaxCapacity == 100) — not the raw AppleRawCurrentCapacity / AppleRawMaxCapacity
                // ratio, which reads a point or two low. Same fix as the Mac's BatteryReader.
                if let relMax = intOrNil(reg["MaxCapacity"]), relMax > 0,
                   let relCur = intOrNil(reg["CurrentCapacity"]) {
                    dev.stateOfCharge = min(100, Double(relCur) / Double(relMax) * 100)
                }
                dev.cycleCount = intOrNil(reg["CycleCount"])
                if let t = intOrNil(reg["Temperature"]) { dev.temperatureC = Double(t) / 100.0 }
                if let v = intOrNil(reg["Voltage"]) { dev.voltageV = Double(v) / 1000.0 }
                if let a = signedIntOrNil(reg["Amperage"]) { dev.amperageA = Double(a) / 1000.0 }
                dev.isCharging = reg["IsCharging"] as? Bool ?? false
                dev.externalConnected = reg["ExternalConnected"] as? Bool ?? false
                dev.fullyCharged = reg["FullyCharged"] as? Bool ?? false
                dev.capturedAt = Date()
            } else if trusted {
                // Diagnostics relay is refused while the device sits at the passcode lock screen
                // (lockdownd returns PASSWORD_PROTECTED), so the detailed registry is unreadable.
                // The device is still here and trusted, though — fall back to the lockdown battery
                // domain for a live charge %, and let publish() keep the last-known health on
                // screen (grafted from cache) rather than dropping to an error.
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

        publish(devices: results, toolsMissing: false, status: nil)
    }

    private func publish(devices fresh: [IOSDeviceInfo], toolsMissing: Bool, status: String?) {
        DispatchQueue.main.async {
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

            let now = Date()
            // Note every UDID currently on the bus (locked/errored devices count as present too),
            // so cache staleness below is judged per-device rather than by a single global clock.
            for dev in fresh { self.lastSeenAt[dev.id] = now }

            // Empty enumeration → device is off the USB bus. Ride out a brief blip, then let it go:
            // a deliberate unplug should clear within a few seconds, not linger.
            if fresh.isEmpty {
                let recent = self.lastGood.filter { self.seenWithin(Self.staleGraceGone, $0.id, now) }
                if !recent.isEmpty {
                    self.devices = recent.map { var d = $0; d.isStale = true; return d }
                    self.statusMessage = nil
                } else {
                    self.devices = []
                    self.statusMessage = status
                        ?? "No iPhone/iPad found over USB or Wi-Fi.\nPlug in the cable (unlock + tap Trust), or turn on “Sync over Wi-Fi” in Finder."
                }
                return
            }

            // Enumeration succeeded. Each fresh read is one of four kinds:
            //  • full read (unlocked)      → shown as-is, becomes the new cached baseline;
            //  • light read (isLightRead)  → glyph-only pass: live charge %, no health read. Grafted
            //                                exactly like a locked read (last-known health from cache,
            //                                never a new baseline), just without the lock badge;
            //  • locked read (isLocked)    → live charge only, so graft the last-known health from
            //                                cache and keep it on screen indefinitely (health barely
            //                                changes; timestamped in the UI). Never a hard error;
            //  • hard failure (errorMessage) → untrusted / handshake dropped: ride out on *this*
            //                                device's own cached data for the grace window, then
            //                                surface the error.
            var merged: [IOSDeviceInfo] = []
            var freshGood: [IOSDeviceInfo] = []
            for dev in fresh {
                if dev.errorMessage == nil, !dev.isLocked, !dev.isLightRead {
                    merged.append(dev)
                    freshGood.append(dev)
                } else if dev.isLocked || dev.isLightRead {
                    var m = dev
                    if let prev = self.lastGood.first(where: { $0.id == dev.id }) {
                        // Graft the static health figures; leave currentCapacity/amperage/temp/
                        // voltage unset so charge stays live (a locked row's lockedChargePercent, a
                        // light read's stateOfCharge) and no stale dynamic values are shown.
                        m.maxCapacity = prev.maxCapacity
                        m.nominalChargeCapacity = prev.nominalChargeCapacity
                        m.designCapacity = prev.designCapacity
                        m.cycleCount = prev.cycleCount
                        m.serial = prev.serial
                        m.capturedAt = prev.capturedAt   // when those health figures were actually read
                    }
                    merged.append(m)   // not added to freshGood: a partial read must not overwrite the baseline
                } else if let prev = self.lastGood.first(where: { $0.id == dev.id }),
                          let cap = prev.capturedAt, now.timeIntervalSince(cap) < Self.staleGraceUnreadable {
                    // Grace measured from THIS device's own last good read, so a healthy sibling
                    // refreshing can't keep resetting it and hide this device's error forever.
                    var s = prev; s.isStale = true
                    merged.append(s)
                } else {
                    merged.append(dev)
                }
            }
            self.devices = merged
            self.statusMessage = nil

            // Merge (don't replace) fresh full reads into the cache so a device that read fully this
            // tick updates its own entry while a sibling that is locked/failed keeps its previously
            // cached good data — otherwise a single healthy device would evict every other device's
            // health from the cache.
            if !freshGood.isEmpty {
                var updated = self.lastGood
                for g in freshGood {
                    if let i = updated.firstIndex(where: { $0.id == g.id }) { updated[i] = g }
                    else { updated.append(g) }
                }
                self.lastGood = updated
            }
            // Prune entries whose device has been off the bus longer than the ride-out window. Runs
            // every publish, so a genuinely departed device doesn't linger (and briefly resurrect
            // when the bus later goes fully empty), while a one-tick enumeration blip keeps its
            // entry — and, for a locked device, its graft baseline.
            self.lastGood = self.lastGood.filter { self.seenWithin(Self.staleGraceGone, $0.id, now) }
        }
    }

    /// True if `id` appeared in a fresh enumeration within `window` of `now`. Main-thread only
    /// (lastSeenAt is only touched inside publish).
    private func seenWithin(_ window: TimeInterval, _ id: String, _ now: Date) -> Bool {
        guard let seen = lastSeenAt[id] else { return false }
        return now.timeIntervalSince(seen) < window
    }
}
