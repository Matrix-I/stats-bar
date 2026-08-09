// AndroidDeviceReader.swift — reads Android battery info over USB by shelling out to adb
// (`dumpsys battery` for the fast per-second values, `dumpsys batterystats` once per connection
// for the learned/rated capacities). Command-line plumbing (locating adb, running with a
// timeout) lives in DeviceTool.

import Foundation
import Combine

private func androidStatusText(_ code: Int?) -> (charging: Bool, full: Bool) {
    (code == 2, code == 5)
}

private func androidHealthText(_ code: Int?) -> String? {
    switch code {
    case 2: return "Good"
    case 3: return "Overheat"
    case 4: return "Dead"
    case 5: return "Over voltage"
    case 6: return "Unspecified failure"
    case 7: return "Cold"
    default: return nil   // 1 (unknown) or missing — not worth showing
    }
}

@MainActor
final class AndroidDeviceReader: ObservableObject {
    @Published var devices: [AndroidDeviceInfo] = []
    @Published var toolsMissing = false
    @Published var statusMessage: String?

    private var isBusy = false
    private lazy var poll = PollingTimer { [weak self] in self?.tick() }

    /// Popover visibility, driven by BatteryDetailView (the only view that shows Android data).
    /// Together with the Android menu-bar glyph it decides how often we look — see `watcher`.
    /// Main-thread only.
    private var panelOpen = false

    /// Which interval applies to which audience, and how long a device may be missing before it is
    /// dropped — the same Sources/Core type IOSDeviceReader uses. `.android` because this reader has no
    /// TemperatureAlerter, so it keeps the slower off-screen interval; see that property.
    private static let cadence = DeviceReadCadence.android

    /// Who can see the readings right now. Both the read cadence and the presence cache's ride-out
    /// window are derived from this.
    private var watcher: DeviceReadCadence.Watcher {
        if panelOpen { return .popover }
        return UserDefaults.standard.bool(forKey: "showAndroidMenuBar") ? .glyph : .nobody
    }

    /// Point the timer at the interval the current audience deserves.
    ///
    /// This replaces a flat 1 Hz timer whose ticks were gated on elapsed time, which is the two-rate
    /// arrangement DeviceReadCadence's header argues against at length: a read starting a few
    /// milliseconds after a tick leaves the next tick fractionally short of the interval, so it skips,
    /// and the effective cadence drifts off the one written down. One rate cannot beat against itself.
    private func applyCadence() {
        poll.schedule(every: Self.cadence.interval(watcher, deviceAttached: !devices.isEmpty))
    }

    /// Which device to show as read and which to keep showing while its reads fail, plus the cache of
    /// last-good reads behind that. The same Sources/Core type IOSDeviceReader uses, so the staleness
    /// rules are shared rather than mirrored: judged per-device, so a healthy phone refreshing can't
    /// keep resetting the grace window and hide another phone's error, and one good read can't evict
    /// another device's cached health. Main-thread only (touched inside publish).
    ///
    /// `graceGone` is re-derived on every publish from the interval actually in force, so the value
    /// passed here only covers the very first read. It used to be a flat 5 s against a keep-warm
    /// cadence of 10 s, which is a ride-out that CANNOT FIRE: by the time the next tick enumerated,
    /// the previous sighting was already twice the age of the window, so the first blip dropped the
    /// device outright. That is precisely the defect DeviceReadCadence was extracted to end for the
    /// iOS reader — the comment here even justified the number by comparison with an iOS constant that
    /// had already been deleted — and it stayed live in this file for the whole time.
    ///
    /// The default 30 s `graceUnreadable` stands: a device still enumerated but unreadable tends to
    /// recover on its own. Nothing here produces `.partial` — an Android read either works or carries
    /// an errorMessage, so there is no locked-device equivalent to graft cached health onto.
    private var presence = DevicePresenceCache<AndroidDeviceInfo, String>(
        graceGone: AndroidDeviceReader.cadence.graceGone(.popover, deviceAttached: false)
    )

    /// Runs the enumeration off the main thread and owns the caches that outlive a single refresh
    /// (device identities, learned battery capacity). See the type for why it is a queue-confined
    /// class rather than an actor.
    private let worker = AndroidDeviceWorker()

    init() {
        refresh()
        applyCadence()
    }

    /// Called by BatteryDetailView's visibility reporter. Forces a read on the opening edge, which is
    /// what BatteryReader and IOSDeviceReader both do.
    ///
    /// The comment here used to claim parity with the iOS reader in NOT forcing one. That stopped
    /// being true when the iOS reader started forcing it, and the asymmetry it left behind is the
    /// reason the Android card was the one still showing the previous keep-warm reading — up to ten
    /// seconds old — at the moment the popover appeared.
    func setPanelOpen(_ open: Bool) {
        guard open != panelOpen else { return }
        panelOpen = open
        applyCadence()
        if open { refresh() }
    }

    /// The timer's handler. The timer already runs at the right interval (see applyCadence), so every
    /// tick is a read; `refresh`'s isBusy guard is what keeps a slow adb cycle from piling up.
    private func tick() { refresh() }

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

    private func publish(devices fresh: [AndroidDeviceInfo], toolsMissing: Bool, status: String?) {
        self.isBusy = false

        // Registered before the early return below, not after it: whether anything is attached is one
        // of the cadence's inputs, and adb going missing empties the list, so that path has to relax
        // the timer too or the reader keeps polling at the attached rate for a tool that is gone.
        // IOSDeviceReader registers its two defers in the same place for the same reason.
        defer { self.applyCadence() }

        if toolsMissing {
            self.toolsMissing = true
            self.devices = []
            self.statusMessage = nil
            return
        }
        self.toolsMissing = false

        // The ride-out window has to track how often we actually look — a window shorter than the
        // polling interval can never fire. `deviceAttached` reads the list as it stands BEFORE this
        // publish rewrites it, which is the conservative reading; the cache itself is what keeps a
        // change here from applying retroactively to sightings taken under the old cadence.
        presence.graceGone = Self.cadence.graceGone(watcher, deviceAttached: !self.devices.isEmpty)

        let resolved = presence.resolve(
            fresh, now: Date(), id: \.id,
            kind: { $0.errorMessage == nil ? .good : .failed },
            capturedAt: \.capturedAt
        )

        // Nothing at all to show. Only reachable from an empty enumeration with nothing recent enough to
        // ride out: any non-empty enumeration resolves to one row per device.
        if resolved.isEmpty {
            self.devices = []
            self.statusMessage = status
                ?? "No Android device found over USB.\nPlug in the cable and enable USB debugging."
            return
        }

        self.devices = resolved.map { row in
            switch row {
            case .fresh(let dev):
                return dev
            case .cachedStale(let prev):
                var s = prev
                s.isStale = true
                return s
            case .grafted(let dev, _):
                // Unreachable: `kind` above never returns .partial. Kept over a fatalError so a future
                // locked-device equivalent degrades to showing the live read rather than crashing.
                return dev
            }
        }
        self.statusMessage = nil
    }
}

/// Owns the adb enumeration and the caches that survive between refreshes. Not an actor, for the same
/// reason as IOSDeviceWorker: every probe blocks on a child process (adb can sit at DeviceTool's full
/// timeout when a phone is locked or the cable is yanked mid-read), and blocking a Swift cooperative
/// thread starves the shared pool. A dedicated serial queue gives the same mutual exclusion — all the
/// state below is touched only from `queue`, which is what makes the @unchecked Sendable sound — on a
/// thread we own and are free to block.
private final class AndroidDeviceWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "StatsBar.AndroidDeviceWorker", qos: .userInitiated)

    private var capacityCache: [String: (max: Int?, design: Int?, cycle: Int?)] = [:]
    private var capacityLastAttempt: [String: Date] = [:]
    private var infoCache: [String: (name: String, manufacturer: String, version: String)] = [:]
    private static let capacityRetryInterval: TimeInterval = 30

    struct RefreshResult: Sendable {
        let devices: [AndroidDeviceInfo]
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

    private func doRefresh() -> RefreshResult {
        guard let adbPath = DeviceTool.path("adb") else {
            return RefreshResult(devices: [], toolsMissing: true, status: nil)
        }

        let listed = listDevices(adbPath)

        let liveSerials = Set(listed.map(\.serial))
        capacityCache = capacityCache.filter { liveSerials.contains($0.key) }
        capacityLastAttempt = capacityLastAttempt.filter { liveSerials.contains($0.key) }
        infoCache = infoCache.filter { liveSerials.contains($0.key) }

        guard !listed.isEmpty else {
            return RefreshResult(devices: [], toolsMissing: false,
                                 status: "No Android device found over USB.\nPlug in the cable and enable USB debugging.")
        }

        var results: [AndroidDeviceInfo] = []
        for entry in listed {
            var dev = AndroidDeviceInfo(id: entry.serial)
            dev.serial = entry.serial

            guard entry.state == "device" else {
                dev.errorMessage = entry.state == "unauthorized"
                    ? "Unlock the phone and tap Allow on the \"Allow USB debugging?\" prompt."
                    : "Device is \(entry.state) — reconnect the cable."
                results.append(dev)
                continue
            }

            if let cached = infoCache[entry.serial] {
                dev.name = cached.name
                dev.manufacturer = cached.manufacturer
                dev.androidVersion = cached.version
            } else {
                let name = getprop(adbPath, serial: entry.serial, key: "ro.product.model") ?? entry.serial
                let manufacturer = getprop(adbPath, serial: entry.serial, key: "ro.product.manufacturer") ?? ""
                let version = getprop(adbPath, serial: entry.serial, key: "ro.build.version.release") ?? ""
                dev.name = name
                dev.manufacturer = manufacturer
                dev.androidVersion = version
                infoCache[entry.serial] = (name, manufacturer, version)
            }

            guard let bat = readBattery(adbPath, serial: entry.serial) else {
                dev.errorMessage = "Couldn't read battery status — reconnect and unlock the phone."
                results.append(dev)
                continue
            }

            let level = Int(bat["level"] ?? "")
            let scale = Int(bat["scale"] ?? "") ?? 100
            if let level, scale > 0 { dev.levelPercent = level * 100 / scale }
            if let counterUah = Int(bat["Charge counter"] ?? ""), counterUah > 0 {
                dev.currentCapacity = counterUah / 1000   // µAh → mAh
            }
            if let v = Int(bat["voltage"] ?? "") { dev.voltageV = Double(v) / 1000.0 }
            if let t = Int(bat["temperature"] ?? "") { dev.temperatureC = Double(t) / 10.0 }
            dev.technology = bat["technology"] ?? ""
            let statusCode = Int(bat["status"] ?? "")
            let (charging, full) = androidStatusText(statusCode)
            dev.isCharging = charging
            dev.fullyCharged = full
            dev.healthText = androidHealthText(Int(bat["health"] ?? ""))
            if let mc = Int(bat["Max charging current"] ?? ""), let mv = Int(bat["Max charging voltage"] ?? ""),
               mc > 0, mv > 0 {
                dev.maxChargingWatts = (Double(mc) / 1_000_000.0) * (Double(mv) / 1_000_000.0)
            }
            dev.cycleCount = cycleCountFromDumpsys(bat)
            dev.externalConnected = ["AC powered", "USB powered", "Wireless powered"]
                .contains { bat[$0] == "true" }
            dev.capturedAt = Date()

            if let cached = capacityCache[entry.serial] {
                dev.maxCapacity = cached.max
                dev.designCapacity = cached.design
                if dev.cycleCount == nil { dev.cycleCount = cached.cycle }
            } else {
                let lastAttempt = capacityLastAttempt[entry.serial]
                if lastAttempt == nil || Date().timeIntervalSince(lastAttempt!) > Self.capacityRetryInterval {
                    capacityLastAttempt[entry.serial] = Date()
                    let cap = readCapacity(adbPath, serial: entry.serial)
                    let cyc = dev.cycleCount
                        ?? readBroadcastCycleCount(adbPath, serial: entry.serial)
                        ?? readSysfsCycleCount(adbPath, serial: entry.serial)
                    if cap.max != nil || cap.design != nil || cyc != nil {
                        capacityCache[entry.serial] = (cap.max, cap.design, cyc)
                        dev.maxCapacity = cap.max
                        dev.designCapacity = cap.design
                        if dev.cycleCount == nil { dev.cycleCount = cyc }
                    }
                }
            }

            results.append(dev)
        }

        return RefreshResult(devices: results, toolsMissing: false, status: nil)
    }

    private func listDevices(_ path: String) -> [(serial: String, state: String)] {
        guard let data = DeviceTool.run(path, ["devices", "-l"]),
              let s = String(data: data, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0 != "List of devices attached" }
            .compactMap { line in
                let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { return nil }
                return (serial: String(parts[0]), state: String(parts[1]).split(separator: " ").first.map(String.init) ?? "")
            }
    }

    private func getprop(_ path: String, serial: String, key: String) -> String? {
        guard let data = DeviceTool.run(path, ["-s", serial, "shell", "getprop", key]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readBattery(_ path: String, serial: String) -> [String: String]? {
        guard let data = DeviceTool.run(path, ["-s", serial, "shell", "dumpsys", "battery"]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        for line in s.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            out[key] = value
        }
        return out.isEmpty ? nil : out
    }

    private func readCapacity(_ path: String, serial: String) -> (max: Int?, design: Int?) {
        let probe = "dumpsys batterystats 2>/dev/null | grep -E 'Estimated battery capacity:|Capacity:'"
        guard let data = DeviceTool.run(path, ["-s", serial, "shell", probe]),
              let s = String(data: data, encoding: .utf8) else { return (nil, nil) }
        var maxCap: Int?
        var designCap: Int?
        for line in s.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if maxCap == nil, t.hasPrefix("Estimated battery capacity:") {
                let rest = t.dropFirst("Estimated battery capacity:".count)
                    .replacingOccurrences(of: "mAh", with: "")
                maxCap = Int(rest.trimmingCharacters(in: .whitespaces))
            } else if designCap == nil, t.hasPrefix("Capacity:") {
                let rest = t.dropFirst("Capacity:".count)
                if let comma = rest.firstIndex(of: ",") {
                    designCap = Int(rest[rest.startIndex..<comma].trimmingCharacters(in: .whitespaces))
                }
            }
            if maxCap != nil && designCap != nil { break }
        }
        return (maxCap, designCap)
    }

    private func cycleCountFromDumpsys(_ bat: [String: String]) -> Int? {
        for (key, value) in bat where key.lowercased().contains("cycle") {
            if let n = Int(value.trimmingCharacters(in: .whitespaces)), n > 0 { return n }
        }
        return nil
    }

    private func readBroadcastCycleCount(_ path: String, serial: String) -> Int? {
        let probe = "dumpsys activity broadcasts 2>/dev/null | " +
                    "grep -o 'android.os.extra.CYCLE_COUNT=[0-9]*' | head -1"
        guard let data = DeviceTool.run(path, ["-s", serial, "shell", probe]),
              let s = String(data: data, encoding: .utf8),
              let eq = s.firstIndex(of: "="),
              let n = Int(s[s.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)),
              n > 0 else { return nil }
        return n
    }

    private func readSysfsCycleCount(_ path: String, serial: String) -> Int? {
        let probe = "for f in /sys/class/power_supply/battery/cycle_count " +
                    "/sys/class/power_supply/bms/cycle_count; do " +
                    "v=$(cat \"$f\" 2>/dev/null); [ -n \"$v\" ] && { echo \"$v\"; break; }; done"
        guard let data = DeviceTool.run(path, ["-s", serial, "shell", probe]),
              let s = String(data: data, encoding: .utf8),
              let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 else { return nil }
        return n
    }
}
