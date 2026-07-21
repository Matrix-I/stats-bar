// BluetoothReader.swift — the ObservableObject behind the Bluetooth menu-bar item. It publishes a
// live BluetoothInfo built from `system_profiler SPBluetoothDataType -json`, which lists the
// connected devices and, for the ones that report it, their battery level(s). That's the same
// source System Settings ▸ Bluetooth and Stats.app read; there's no lighter public API that gives
// per-device battery for arbitrary accessories (the IORegistry only carries it for a subset).
//
// system_profiler is comparatively slow (~0.3–1 s) and forks a helper, so — unlike the CPU/network
// load samples — this never runs on the main thread and never runs on a tight loop. It runs on a
// utility queue, cached, and only while the popover is open (plus one read at startup so the first
// open shows instantly). The menu-bar glyph itself is static, so nothing needs polling while closed.

import Foundation
import Combine

final class BluetoothReader: ObservableObject {
    @Published var info = BluetoothInfo()

    private var timer: Timer?
    private var panelOpen = false

    // Off-main read plumbing, mirroring BatteryReader's gated system_profiler read: at most one read
    // in flight, throttled to `interval`, result handed back on main where `info` is published.
    private let queue = DispatchQueue(label: "BluetoothReader.profiler", qos: .utility)
    private var readInFlight = false
    private var lastRead = Date.distantPast
    private static let interval: TimeInterval = 5   // while the panel is open

    init() {
        // Prime the cache once so the first popover open renders immediately, not a tick later.
        maybeRead(force: true)
    }

    /// Poll every few seconds while the popover is visible; stop entirely when it closes (the
    /// menu-bar glyph carries no live data, so there's nothing to keep current in the background).
    func setPanelOpen(_ open: Bool) {
        guard open != panelOpen else { return }
        panelOpen = open
        if open {
            maybeRead(force: true)
            let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.maybeRead() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// User-driven Refresh button: re-read now regardless of the throttle.
    func refresh() { maybeRead(force: true) }

    /// Kick off a background read unless one is already running or the throttle window hasn't
    /// elapsed. `force` bypasses the throttle (startup + the Refresh button).
    private func maybeRead(force: Bool = false) {
        guard !readInFlight else { return }
        guard force || Date().timeIntervalSince(lastRead) >= Self.interval else { return }
        readInFlight = true
        queue.async { [weak self] in
            let parsed = Self.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastRead = Date()
                self.readInFlight = false
                if let parsed { self.info = parsed }
            }
        }
    }

    // MARK: - Parsing

    /// Runs system_profiler and parses its JSON into a BluetoothInfo, or nil on any failure (tool
    /// missing, timed out via DeviceTool, or an unexpected shape). Reuses DeviceTool.run for the
    /// hard timeout + concurrent pipe draining so a wedged helper can never hang the queue.
    private static func read() -> BluetoothInfo? {
        guard let data = DeviceTool.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["SPBluetoothDataType"] as? [[String: Any]],
              let top = arr.first else { return nil }

        var out = BluetoothInfo()
        out.hasLoaded = true

        // Controller power state — "attrib_on" when Bluetooth is enabled. Absent entirely when the
        // machine has no controller reachable, which we treat as "off".
        if let controller = top["controller_properties"] as? [String: Any],
           let state = controller["controller_state"] as? String {
            out.poweredOn = (state == "attrib_on")
        }

        // Each entry in device_connected is a single-key dict: { "<device name>": { props… } }.
        if let connected = top["device_connected"] as? [[String: Any]] {
            for entry in connected {
                guard let (rawName, value) = entry.first,
                      let props = value as? [String: Any] else { continue }
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                out.connected.append(BluetoothDeviceInfo(
                    name: name.isEmpty ? "Unknown" : name,
                    address: (props["device_address"] as? String) ?? name,
                    minorType: props["device_minorType"] as? String,
                    batteryMain: percent(props["device_batteryLevelMain"]),
                    batteryLeft: percent(props["device_batteryLevelLeft"]),
                    batteryRight: percent(props["device_batteryLevelRight"]),
                    batteryCase: percent(props["device_batteryLevelCase"])
                ))
            }
        }

        // A powered-on controller with connected devices, or explicitly off — either way it's a
        // valid snapshot to publish.
        return out
    }

    /// system_profiler reports battery as a string like "100%". Pull the leading integer out of
    /// whatever it hands us (string or number), clamped to 0…100; nil when there's no usable value.
    /// Percentages are never negative, so we only accept leading digits (a "-" mid-string, or any
    /// non-numeric value like "Not Charging", yields nil rather than a bogus number).
    private static func percent(_ any: Any?) -> Int? {
        if let n = any as? Int { return min(100, max(0, n)) }
        guard let s = any as? String else { return nil }
        let digits = s.prefix { $0.isNumber }
        guard let n = Int(digits) else { return nil }
        return min(100, n)
    }
}
