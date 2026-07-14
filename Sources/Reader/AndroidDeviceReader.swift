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

final class AndroidDeviceReader: ObservableObject {
    @Published var devices: [AndroidDeviceInfo] = []
    @Published var toolsMissing = false
    @Published var statusMessage: String?

    private var isBusy = false
    private var timer: Timer?

    private var lastGood: [AndroidDeviceInfo] = []
    private var lastGoodAt: Date?
    private static let staleGraceGone: TimeInterval = 5
    private static let staleGraceUnreadable: TimeInterval = 30

    /// `dumpsys batterystats` (unlike the fast per-second `dumpsys battery`) can dump several MB of
    /// history and take a while, so it's only fetched once per connected serial and cached — not
    /// worth re-running every second for numbers that barely change. Only touched from doRefresh(),
    /// which refresh()'s isBusy guard ensures never runs concurrently with itself.
    private var capacityCache: [String: (max: Int?, design: Int?)] = [:]
    private var capacityLastAttempt: [String: Date] = [:]
    private static let capacityRetryInterval: TimeInterval = 30

    init() {
        refresh()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.doRefresh()
        }
    }

    /// Parses `adb devices -l` into (serial, state) pairs — state is "device", "unauthorized", or
    /// "offline". Unlike idevice_id, adb only needs one call (no separate USB-enumeration retry loop).
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

    /// `dumpsys battery` prints plain "  Key: value" lines — no plist/JSON on Android.
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

    /// `dumpsys batterystats` has no plist/JSON either, just free-form text. Two lines matter:
    ///   "Estimated battery capacity: 3932 mAh"       — Android's coulomb-counter learned full charge
    ///   "Capacity: 4000, Computed drain: ..., ..."   — OEM-declared rated/design capacity, under the
    ///                                                   "Estimated power use (mAh):" section
    /// Confirmed against a real device (Redmi Note 7): 3932 / 4000 mAh, matching its published spec.
    private func readCapacity(_ path: String, serial: String) -> (max: Int?, design: Int?) {
        guard let data = DeviceTool.run(path, ["-s", serial, "shell", "dumpsys", "batterystats"]),
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

    private func doRefresh() {
        guard let adbPath = DeviceTool.path("adb") else {
            publish(devices: [], toolsMissing: true, status: nil)
            return
        }

        let listed = listDevices(adbPath)
        guard !listed.isEmpty else {
            publish(devices: [], toolsMissing: false,
                    status: "No Android device found over USB.\nPlug in the cable and enable USB debugging.")
            return
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

            dev.name = getprop(adbPath, serial: entry.serial, key: "ro.product.model") ?? entry.serial
            dev.manufacturer = getprop(adbPath, serial: entry.serial, key: "ro.product.manufacturer") ?? ""
            dev.androidVersion = getprop(adbPath, serial: entry.serial, key: "ro.build.version.release") ?? ""

            guard let bat = readBattery(adbPath, serial: entry.serial) else {
                dev.errorMessage = "Couldn't read battery status — reconnect and unlock the phone."
                results.append(dev)
                continue
            }

            let level = Int(bat["level"] ?? "")
            let scale = Int(bat["scale"] ?? "") ?? 100
            if let level, scale > 0 { dev.levelPercent = level * 100 / scale }
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
            dev.cycleCount = Int(bat["Charge cycles"] ?? "")   // Android 14+ only, best-effort (see field doc)
            dev.externalConnected = ["AC powered", "USB powered", "Wireless powered"]
                .contains { bat[$0] == "true" }
            dev.capturedAt = Date()

            if let cached = capacityCache[entry.serial] {
                dev.maxCapacity = cached.max
                dev.designCapacity = cached.design
            } else {
                let lastAttempt = capacityLastAttempt[entry.serial]
                if lastAttempt == nil || Date().timeIntervalSince(lastAttempt!) > Self.capacityRetryInterval {
                    capacityLastAttempt[entry.serial] = Date()
                    let cap = readCapacity(adbPath, serial: entry.serial)
                    if cap.max != nil || cap.design != nil {
                        capacityCache[entry.serial] = cap
                        dev.maxCapacity = cap.max
                        dev.designCapacity = cap.design
                    }
                }
            }

            results.append(dev)
        }

        publish(devices: results, toolsMissing: false, status: nil)
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
            let sinceGood = self.lastGoodAt.map { now.timeIntervalSince($0) } ?? .infinity

            if fresh.isEmpty {
                if sinceGood < Self.staleGraceGone, !self.lastGood.isEmpty {
                    self.devices = self.lastGood.map { var d = $0; d.isStale = true; return d }
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
                if dev.errorMessage != nil, sinceGood < Self.staleGraceUnreadable,
                   let prev = self.lastGood.first(where: { $0.id == dev.id }) {
                    var s = prev; s.isStale = true
                    merged.append(s)
                } else {
                    merged.append(dev)
                    if dev.errorMessage == nil { freshGood.append(dev) }
                }
            }
            self.devices = merged
            self.statusMessage = nil

            if !freshGood.isEmpty {
                self.lastGood = freshGood
                self.lastGoodAt = now
            }
        }
    }
}
