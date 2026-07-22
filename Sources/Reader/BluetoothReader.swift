// BluetoothReader.swift — the ObservableObject behind the Bluetooth menu-bar item. It publishes a
// live BluetoothInfo from two sources, merged by device:
//
//   • `system_profiler SPBluetoothDataType -json` — the device list (names, types, connected state)
//     plus battery for the devices macOS caches it for: classic accessories (e.g. headsets) and some
//     BLE keyboards. This is the same source System Settings ▸ Bluetooth reads.
//   • CoreBluetooth GATT (see BluetoothGATT) — battery for BLE accessories that system_profiler
//     omits, notably Logitech mice. Those publish their level only over the GATT Battery Service, so
//     this is the ONLY route that gets e.g. the MX Anywhere 3's percentage. It fills any main-battery
//     value system_profiler left blank, matched by device name.
//
// system_profiler is comparatively slow (~0.3–1 s) and forks a helper, so it runs on a utility
// queue, cached, and only while the popover is open (plus one read at startup so the first open
// shows instantly). Its parse (`baseInfo`) is kept separately from what's published so a later GATT
// update can be re-merged onto it without a fresh system_profiler read. The GATT source runs its own
// CoreBluetooth callbacks on the main thread and calls back here whenever a level changes.

import Foundation
import Combine

final class BluetoothReader: ObservableObject {
    @Published var info = BluetoothInfo()

    private lazy var poll = PollingTimer { [weak self] in self?.maybeRead() }
    private var panelOpen = false

    /// The last system_profiler parse, before the GATT overlay — so a GATT update re-merges onto the
    /// real device list instead of a stale published copy. Main-thread only.
    private var baseInfo = BluetoothInfo()

    /// Live BLE battery source (CoreBluetooth). Delivers on the main thread; a level change re-merges
    /// and republishes without waiting for the next system_profiler read.
    private let gatt = BluetoothGATT()

    // Off-main read plumbing, shared via ThrottledBackgroundValue: at most one read in flight,
    // throttled to `interval`, result handed back on main where `info` is published.
    private lazy var profilerRead = ThrottledBackgroundValue<BluetoothInfo?>(label: "BluetoothReader.profiler", every: Self.interval)
    private static let interval: TimeInterval = 5   // while the panel is open (also the poll cadence)

    init() {
        gatt.onUpdate = { [weak self] in self?.republish() }
        // Prime the cache once so the first popover open renders immediately, not a tick later.
        maybeRead(force: true)
    }

    /// Poll every few seconds while the popover is visible; stop the system_profiler timer when it
    /// closes. (The CoreBluetooth source stays live regardless — it's cheap and event-driven.)
    func setPanelOpen(_ open: Bool) {
        guard open != panelOpen else { return }
        panelOpen = open
        if open {
            maybeRead(force: true)
            gatt.refresh()
            poll.schedule(every: Self.interval)
        } else {
            poll.stop()
        }
    }

    /// User-driven Refresh button: re-read now regardless of the throttle.
    func refresh() { maybeRead(force: true); gatt.refresh() }

    /// Kick off a background read unless one is already running or the throttle window hasn't
    /// elapsed. `force` bypasses the throttle (startup + the Refresh button).
    private func maybeRead(force: Bool = false) {
        profilerRead.request(force: force, produce: { Self.read() }) { [weak self] parsed in
            guard let self else { return }
            if let parsed {
                self.baseInfo = parsed
                self.info = self.merged(parsed)
            }
            self.gatt.refresh()   // pick up any newly connected BLE peripherals
        }
    }

    /// Re-overlay the current GATT levels onto the last system_profiler parse and publish. Called on
    /// the main thread when a GATT battery value changes.
    private func republish() { info = merged(baseInfo) }

    /// A copy of `base` with each device's main battery filled from the GATT source (by name) when
    /// system_profiler didn't report one. system_profiler's own value always wins when present.
    private func merged(_ base: BluetoothInfo) -> BluetoothInfo {
        guard !gatt.levelsByName.isEmpty else { return base }
        var out = base
        out.connected = base.connected.map { device in
            guard device.batteryMain == nil, let pct = gatt.levelsByName[device.name] else { return device }
            return BluetoothDeviceInfo(
                name: device.name, address: device.address, minorType: device.minorType,
                batteryMain: pct,
                batteryLeft: device.batteryLeft, batteryRight: device.batteryRight, batteryCase: device.batteryCase
            )
        }
        return out
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
