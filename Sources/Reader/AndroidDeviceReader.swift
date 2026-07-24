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

    /// Popover visibility, driven by BatteryDetailView (the only view that shows Android data). While
    /// the popover is closed AND the Android menu-bar glyph is off, nothing consumes `devices`, so the
    /// reader drops from its ~1 Hz cadence to a slow keep-warm — see tick(). Main-thread only.
    private var panelOpen = false
    private var lastRefreshAt = Date.distantPast
    private static let keepWarmInterval: TimeInterval = 10

    /// Cache of the most recently read devices (only touched on the main thread, inside publish) —
    /// keeps showing data across a brief USB drop instead of the device "vanishing".
    private var lastGood: [AndroidDeviceInfo] = []
    /// Last time each serial appeared in a fresh enumeration, so cache staleness is judged per-device
    /// rather than by a single global clock: a healthy phone refreshing can't keep resetting the
    /// grace window (and hide another phone's error), and one good read can't evict another device's
    /// cached health. Mirrors IOSDeviceReader.lastSeenAt. Main-thread only (touched inside publish).
    private var lastSeenAt: [String: Date] = [:]
    private static let staleGraceGone: TimeInterval = 5
    private static let staleGraceUnreadable: TimeInterval = 30

    /// Dedicated worker actor encapsulating background enumeration & caching
    private let worker = AndroidDeviceWorker()

    init() {
        refresh()
        poll.schedule(every: 1)
    }

    /// Called by BatteryDetailView's visibility reporter. Like the iOS reader, no forced read on open
    /// — the next fast tick (within ~1 s) refreshes and the warm cache shows meanwhile.
    func setPanelOpen(_ open: Bool) { panelOpen = open }

    /// The 1 Hz timer's handler. Runs a full refresh() while the popover is open OR the Android
    /// menu-bar glyph is enabled (it shows a live phone %, rebuilt ~1 Hz by AppDelegate). Otherwise it
    /// merely keeps the cache warm on a slow cadence, so opening the popover still shows recent data
    /// instead of shelling out to adb every second for something nobody is looking at.
    private func tick() {
        let active = panelOpen || UserDefaults.standard.bool(forKey: "showAndroidMenuBar")
        guard active || Date().timeIntervalSince(lastRefreshAt) >= Self.keepWarmInterval else { return }
        lastRefreshAt = Date()
        refresh()
    }

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        let worker = self.worker
        Task.detached(priority: .userInitiated) { [weak self] in
            let res = await worker.doRefresh()
            Task { @MainActor [weak self] in
                self?.publish(devices: res.devices, toolsMissing: res.toolsMissing, status: res.status)
            }
        }
    }

    private func publish(devices fresh: [AndroidDeviceInfo], toolsMissing: Bool, status: String?) {
        DispatchQueue.main.async {
            self.isBusy = false

            if toolsMissing {
                self.toolsMissing = true
                self.devices = []
                self.statusMessage = nil
                return
            }
            self.toolsMissing = false

            let now = Date()
            // Note every serial currently on the bus (errored/offline devices count as present too),
            // so cache staleness below is judged per-device rather than by a single global clock.
            for dev in fresh { self.lastSeenAt[dev.id] = now }

            // Empty enumeration → nothing on the bus. Ride out a brief blip, then let it go: a
            // deliberate unplug should clear within a few seconds, not linger.
            if fresh.isEmpty {
                let recent = self.lastGood.filter { self.seenWithin(Self.staleGraceGone, $0.id, now) }
                if !recent.isEmpty {
                    self.devices = recent.map { var d = $0; d.isStale = true; return d }
                    self.statusMessage = nil
                } else {
                    self.devices = []
                    self.statusMessage = status
                        ?? "No Android device found over USB.\nPlug in the cable and enable USB debugging."
                }
                return
            }

            var merged: [AndroidDeviceInfo] = []
            var freshGood: [AndroidDeviceInfo] = []
            for dev in fresh {
                if dev.errorMessage == nil {
                    merged.append(dev)
                    freshGood.append(dev)
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

            // Merge (don't replace) fresh good reads into the cache so a device that read OK this tick
            // updates its own entry while a sibling that errored keeps its previously cached good data
            // — otherwise a single healthy device would evict every other device's health.
            if !freshGood.isEmpty {
                var updated = self.lastGood
                for g in freshGood {
                    if let i = updated.firstIndex(where: { $0.id == g.id }) { updated[i] = g }
                    else { updated.append(g) }
                }
                self.lastGood = updated
            }
            // Prune entries whose device has been off the bus longer than the ride-out window, so a
            // genuinely departed device doesn't linger (or briefly resurrect when the bus later goes
            // fully empty), while a one-tick enumeration blip keeps its cached entry.
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

private actor AndroidDeviceWorker {
    private var capacityCache: [String: (max: Int?, design: Int?, cycle: Int?)] = [:]
    private var capacityLastAttempt: [String: Date] = [:]
    private var infoCache: [String: (name: String, manufacturer: String, version: String)] = [:]
    private static let capacityRetryInterval: TimeInterval = 30

    struct RefreshResult: Sendable {
        let devices: [AndroidDeviceInfo]
        let toolsMissing: Bool
        let status: String?
    }

    func doRefresh() -> RefreshResult {
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
