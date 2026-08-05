// BluetoothReader.swift — the ObservableObject behind the Bluetooth menu-bar item. It publishes a
// live BluetoothInfo from three sources, merged by device:
//
//   • `system_profiler SPBluetoothDataType -json` — the device list (names, types, connected state)
//     plus battery for the devices macOS caches it for: some BLE keyboards. This is the same source
//     System Settings ▸ Bluetooth reads.
//   • IOKit accessory power sources (see AccessoryPowerSource) — the widest of the three, and the
//     only one that can see a Bluetooth CLASSIC device at all. Synchronous and ~0.09 ms.
//   • CoreBluetooth GATT (see BluetoothGATT) — battery for BLE accessories, notably Logitech mice.
//     Kept because it has been proved on hardware and the accessory channel has not yet been proved
//     to cover every shape (earbuds in particular). It fills whatever the first two left blank.
//
// The three overlap but none subsumes the others in what has been measured, which is the whole
// reason for merging rather than picking one: on the author's machine system_profiler covers only
// the keyboard, GATT only the mouse, and the accessory channel all three — the headset ONLY there.
// A headset showing "—" for four releases is what this arrangement was written to fix, and it was a
// missing source rather than a broken parse.
//
// Fields are filled INDIVIDUALLY rather than a whole device at a time. The previous overlay rebuilt
// the struct from the source it was applying, so a device that reported left/right/case but no main
// level would have had all three replaced by one merged main — the levels were dropped by the code
// that was meant to be adding one.
//
// system_profiler is comparatively slow (~0.3–1 s) and forks a helper, so it runs on a utility
// queue, cached, and only while the popover is open (plus one read at startup so the first open
// shows instantly). Its parse (`baseInfo`) is kept separately from what's published so a later GATT
// update can be re-merged onto it without a fresh system_profiler read. The GATT source runs its own
// CoreBluetooth callbacks on the main thread and calls back here whenever a level changes.

import Foundation
import Combine

@MainActor
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
    // throttled to `profilerThrottle`, result handed back on main where `info` is published.
    private lazy var profilerRead = ThrottledBackgroundValue<BluetoothInfo?>(label: "BluetoothReader.profiler", every: Self.profilerThrottle)
    private static let interval: TimeInterval = 5   // poll cadence while the panel is open
    // ThrottledBackgroundValue measures the gap since the previous COMPLETION, so a throttle equal to
    // the poll cadence skips every other tick (only `interval − readTime` has elapsed at each tick) and
    // halves the effective refresh rate. Keep the throttle comfortably below the poll cadence so every
    // tick runs, while still coalescing bursts (e.g. a forced open landing next to a scheduled tick).
    private static let profilerThrottle: TimeInterval = 3.5

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

    /// A copy of `base` with every battery field system_profiler left blank filled from the other two
    /// sources, in decreasing order of authority. Nothing already present is overwritten, so a value
    /// that came from macOS's own device record always wins.
    ///
    /// The accessory read happens here rather than alongside system_profiler on the background queue
    /// because it costs 0.09 ms and this runs on every republish — reading it fresh is cheaper than
    /// the bookkeeping to cache it, and it means a GATT-triggered republish can't pair a new GATT
    /// level with a stale accessory list.
    private func merged(_ base: BluetoothInfo) -> BluetoothInfo {
        var out = base

        let accessories = AccessoryPowerSource.read()
        let levels = AccessoryBatteryJoin.levels(
            devices: base.connected.map {
                DeviceIdentity(name: $0.name, vendorID: $0.vendorID, productID: $0.productID)
            },
            accessories: accessories
        )

        for i in out.connected.indices {
            let accessory = levels[i]
            if out.connected[i].batteryMain == nil { out.connected[i].batteryMain = accessory.main }
            if out.connected[i].batteryLeft == nil { out.connected[i].batteryLeft = accessory.left }
            if out.connected[i].batteryRight == nil { out.connected[i].batteryRight = accessory.right }
            if out.connected[i].batteryCase == nil { out.connected[i].batteryCase = accessory.caseLevel }

            // GATT reports one level per peripheral and has only ever been keyed by name; it is the
            // last resort precisely because that key is weaker than the join above.
            if out.connected[i].batteryMain == nil,
               let pct = gatt.levelsByName[out.connected[i].name] {
                out.connected[i].batteryMain = pct
            }
        }

        return out
    }

    // MARK: - Parsing

    /// Runs system_profiler and parses its JSON into a BluetoothInfo, or nil on any failure (tool
    /// missing, timed out via DeviceTool, or an unexpected shape). Reuses DeviceTool.run for the
    /// hard timeout + concurrent pipe draining so a wedged helper can never hang the queue.
    nonisolated private static func read() -> BluetoothInfo? {
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
                    vendorID: hexID(props["device_vendorID"]),
                    productID: hexID(props["device_productID"]),
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
    /// system_profiler reports the USB-style IDs as hex strings — "0x054C", and "0x004C (Apple)" on
    /// the entries that name the vendor. The accessory power sources report the same IDs as plain
    /// decimal numbers, so one side has to be converted before they can be compared. nil for a device
    /// that reports no ID, which is common enough that the join must not depend on it.
    nonisolated private static func hexID(_ any: Any?) -> Int? {
        guard let raw = any as? String else { return any as? Int }
        let token = raw.trimmingCharacters(in: .whitespaces).prefix { !$0.isWhitespace }
        guard token.lowercased().hasPrefix("0x") else { return Int(token) }
        return Int(token.dropFirst(2), radix: 16)
    }

    nonisolated private static func percent(_ any: Any?) -> Int? {
        if let n = any as? Int { return min(100, max(0, n)) }
        guard let s = any as? String else { return nil }
        let digits = s.prefix { $0.isNumber }
        guard let n = Int(digits) else { return nil }
        return min(100, n)
    }
}
