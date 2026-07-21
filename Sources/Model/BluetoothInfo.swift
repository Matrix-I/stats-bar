// BluetoothInfo.swift — live Bluetooth model: the controller's power state plus the list of
// currently connected devices, each with its display name, minor type (Mouse/Keyboard/Headset…)
// and whatever battery levels macOS exposes for it. Populated by BluetoothReader from
// `system_profiler SPBluetoothDataType -json`, the same source the Bluetooth pane in System
// Settings and Stats.app read.

import Foundation

/// One connected Bluetooth device. Battery is optional and can arrive in several shapes: a single
/// `main` level for mice/keyboards/headsets, or the `left`/`right`/`case` triplet for AirPods-style
/// earbuds. Every field is nil when the device doesn't report it (many mice never publish a level).
struct BluetoothDeviceInfo: Identifiable {
    let name: String
    let address: String       // BD_ADDR, e.g. "E0:57:98:2A:4C:0C" — stable, so it's the identity
    let minorType: String?    // "Mouse", "Keyboard", "Headset", "Speaker", … (device_minorType)

    let batteryMain: Int?
    let batteryLeft: Int?
    let batteryRight: Int?
    let batteryCase: Int?

    var id: String { address }

    /// True when macOS reports at least one battery level for this device.
    var hasBattery: Bool {
        batteryMain != nil || batteryLeft != nil || batteryRight != nil || batteryCase != nil
    }

    /// The single headline percentage for the row's right edge: the main level when present,
    /// otherwise the lower of the two earbud levels (the one you'd charge first). The case level is
    /// deliberately NOT folded in — a drained case sitting in a drawer must not make healthy buds
    /// read as nearly dead; it's surfaced separately in `batteryDetail`. Falls back to the case
    /// level only when it's the sole reading (buds out of range), where `batteryDetail` labels it.
    /// nil when the device reports no battery at all.
    var headlineBattery: Int? {
        if let m = batteryMain { return m }
        let buds = [batteryLeft, batteryRight].compactMap { $0 }
        if let low = buds.min() { return low }
        return batteryCase
    }

    /// A "L 80% · R 78% · Case 90%" caption breaking out every split level a device reports, or nil
    /// when there's only a single main level (already shown as the headline) or no battery at all.
    /// Shown even for a lone side/case reading, so an unlabelled headline % is never mistaken for
    /// the device's main battery.
    var batteryDetail: String? {
        guard batteryMain == nil else { return nil }
        var parts: [String] = []
        if let l = batteryLeft { parts.append("L \(l)%") }
        if let r = batteryRight { parts.append("R \(r)%") }
        if let c = batteryCase { parts.append("Case \(c)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// An SF Symbol that suits the device's minor type, for the row's leading glyph. Falls back to a
    /// generic wireless symbol for anything unrecognised (or a device that reports no type).
    var symbolName: String {
        let t = (minorType ?? "").lowercased()
        if t.contains("mouse") { return "computermouse.fill" }
        if t.contains("keyboard") { return "keyboard" }
        if t.contains("headphone") || t.contains("headset") { return "headphones" }
        if t.contains("speaker") { return "hifispeaker.fill" }
        if t.contains("controller") || t.contains("gamepad") || t.contains("joystick") { return "gamecontroller.fill" }
        return "dot.radiowaves.left.and.right"
    }
}

struct BluetoothInfo {
    /// False until the first successful system_profiler read lands. Lets the view show a neutral
    /// "Reading…" placeholder instead of asserting "Bluetooth is off." from the default (unread)
    /// state — the default `poweredOn == false` is indistinguishable from a genuine "off" reading.
    var hasLoaded = false
    /// The controller's power state — false when Bluetooth is turned off (or no controller exists).
    var poweredOn = false
    /// Devices currently connected, in the order system_profiler lists them.
    var connected: [BluetoothDeviceInfo] = []
}
