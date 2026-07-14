// BatteryDetailView.swift — the popover shown when the menu-bar item is clicked: live fans,
// the Mac battery + health + power readout, the iPhone/Android sections, settings toggles, and
// the height-management machinery that lets the popover scroll instead of overflowing the screen.

import SwiftUI
import AppKit

/// Reports the true (unclipped) height of the ScrollView's content, so the popover can be sized
/// to `min(content height, cap)` instead of relying on ScrollView's own ideal size — which SwiftUI
/// reports as ~0 in an auto-sizing container like MenuBarExtra(.window), making the window vanish.
private struct PanelHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Take the max, not the last value: the background GeometryReader emits a spurious 0 during
        // an early layout pass alongside the real content height, and `value = nextValue()` let that
        // 0 clobber the real measurement — leaving measuredContentHeight stuck at 0 so the popover
        // never switched to the scrolling branch. max() keeps the real height; each layout pass
        // recomputes from scratch, so it still tracks the content shrinking.
        value = max(value, nextValue())
    }
}

struct BatteryDetailView: View {
    @ObservedObject var reader: BatteryReader
    @ObservedObject var iosReader: IOSDeviceReader
    @ObservedObject var androidReader: AndroidDeviceReader
    @AppStorage("showMenuBarPercent") private var showMenuBarPercent = true
    @AppStorage("showIPhoneMenuBar") private var showIPhoneMenuBar = false
    @AppStorage("showAndroidMenuBar") private var showAndroidMenuBar = false

    @AppStorage("showMacFullDetails") private var showMacFullDetails = false
    @AppStorage("showMacPowerLiveDetails") private var showMacPowerLiveDetails = false

    // visibleFrame height of the screen the popover is *actually* shown on. MenuBarExtra can open
    // the popover on any display (in a multi-monitor setup it follows the active menu bar, not
    // necessarily the primary screen), so WindowVisibilityReporter feeds us the real one via
    // `window.screen`. Seeded with a sensible menu-bar-screen guess for the very first layout pass.
    @State private var panelScreenHeight: CGFloat = BatteryDetailView.initialScreenHeight

    // Fraction of the shown-on screen's height the popover may occupy before it starts scrolling.
    private static let panelHeightFraction: CGFloat = 0.8

    // Caps the popover so it never grows past `panelHeightFraction` of the screen it's shown on —
    // beyond that, the content scrolls instead of pushing the window further down.
    private var maxPanelHeight: CGFloat { panelScreenHeight * Self.panelHeightFraction }

    // Best guess before the popover window exists: the menu-bar screen (frame origin (0,0) in
    // AppKit's global space — rock-solid, unlike screens[] order or focus-following NSScreen.main).
    private static var initialScreenHeight: CGFloat {
        let menuBarScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first
            ?? NSScreen.main
        return menuBarScreen?.visibleFrame.height ?? 800
    }

    // Starts pinned to the cap so the very first layout pass is never 0pt tall (which made the
    // popover invisible) — GeometryReader below then corrects it down to the content's real size.
    @State private var measuredContentHeight: CGFloat = BatteryDetailView.initialScreenHeight * BatteryDetailView.panelHeightFraction

    var body: some View {
        // Render un-scrolled by default (identical to the plain auto-sizing VStack this used to
        // be) so the very first layout pass always has a well-defined size and the popover shows.
        // Only once we've actually measured content taller than the cap do we switch to a
        // ScrollView with a concrete fixed height — never an ambiguous/ideal-only constraint,
        // which is what made the window vanish before.
        Group {
            if measuredContentHeight > maxPanelHeight {
                ScrollView { panelContent.background(OverlayScrollerConfigurator()) }
                    .frame(height: maxPanelHeight)
            } else {
                panelContent
            }
        }
        .frame(width: 300)
        .background(WindowVisibilityReporter(
            onChange: { open in
                reader.setPanelOpen(open)
                if open {
                    iosReader.refresh()      // one immediate read on open; it stays on its slow cadence
                    androidReader.refresh()
                }
            },
            onScreenHeight: { h in if h > 0 { panelScreenHeight = h } }
        ))
    }

    @ViewBuilder
    private var panelContent: some View {
        let i = reader.info
        VStack(alignment: .leading, spacing: 12) {

            // 🌀 Fan speeds from the SMC (live, ~1 Hz) — pinned above the battery readout.
            // Skipped entirely on fanless Macs (e.g. MacBook Air), so the battery header stays first there.
            if !i.fans.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("🌀 Fans (live)").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(i.fans.enumerated()), id: \.offset) { idx, rpm in
                        InfoRow(label: i.fans.count > 1 ? "Fan \(idx + 1)" : "Fan",
                                value: "\(Int(rpm.rounded())) rpm")
                    }
                }

                Divider()
            }

            // 🧠 Live RAM breakdown (App / Wired / Compressed / Free + swap) — pinned right below
            // the fans, above the battery readout. nil only if the VM stats read fails.
            if let mem = i.memory {
                MacMemorySection(mem: mem)
                Divider()
            }

            // Header
            HStack {
                Text("🔋 Battery").font(.headline)
                Spacer()
                Text(i.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Current charge
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Current charge")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", i.chargePercent))
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                }
                BarView(pct: i.chargePercent, color: .blue)
                Text("\(i.currentCapacity) / \(i.maxCapacity) mAh")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }

            // Health
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Health (vs design)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", i.healthPercent))
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(healthColor(i.healthPercent))
                }
                BarView(pct: i.healthPercent, color: healthColor(i.healthPercent))
                Text("\(i.maxCapacity) / \(i.designCapacity) mAh (design)")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }

            ZStack {
                Divider()
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showMacFullDetails.toggle()
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(showMacFullDetails ? Color.white : Color.secondary)
                            .padding(4)
                            .background(
                                Circle().fill(showMacFullDetails ? Color.accentColor : Color.secondary.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(showMacFullDetails ? "Show less" : "Show more")
                }
            }

            VStack(spacing: 6) {
                InfoRow(label: "Full charge capacity", value: "\(i.maxCapacity) mAh")
                InfoRow(label: "Design capacity", value: "\(i.designCapacity) mAh")
                InfoRow(label: "Cycle count", value: "\(i.cycleCount)")
                if showMacFullDetails {
                    InfoRow(label: "Temperature",
                            value: String(format: "%.1f °C", i.temperatureC))
                    InfoRow(label: "Voltage",
                            value: String(format: "%.2f V", i.voltageV))
                    InfoRow(label: "Power", value: powerText(i))
                    if i.externalConnected && i.adapterWatts > 0 {
                        InfoRow(label: "Adapter",
                                value: "\(i.adapterWatts) W \(i.adapterName)")
                    }
                    InfoRow(label: "Status", value: statusText(i))
                    if !i.serial.isEmpty {
                        InfoRow(label: "Serial", value: i.serial)
                    }
                }
            }

            // ⚡ Live power rails from the SMC — these tick every second, unlike the
            // battery-gauge values above (which the OS only refreshes every ~30–60 s).
            if i.smcSystemTotalW != nil || i.smcDCInW != nil {
                ZStack {
                    Divider()
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showMacPowerLiveDetails.toggle()
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(showMacPowerLiveDetails ? Color.white : Color.secondary)
                                .padding(4)
                                .background(
                                    Circle().fill(showMacPowerLiveDetails ? Color.accentColor : Color.secondary.opacity(0.15))
                                )
                        }
                        .buttonStyle(.plain)
                        .help(showMacPowerLiveDetails ? "Show less" : "Show more")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("⚡ Power (live)").font(.caption).foregroundStyle(.secondary)
                    if let v = i.smcSystemTotalW { InfoRow(label: "System Total", value: String(format: "%.2f W", v)) }
                    if showMacPowerLiveDetails {
                        if let v = i.smcDCInW, v > 0.05 { InfoRow(label: "DC In", value: String(format: "%.2f W", v)) }
                        if let v = i.smcBrightnessW, v > 0.05 { InfoRow(label: "Display", value: String(format: "%.2f W", v)) }
                        if let v = i.smcThunderboltLW { InfoRow(label: "Thunderbolt L", value: String(format: "%.2f W", v)) }
                        if let v = i.smcThunderboltRW { InfoRow(label: "Thunderbolt R", value: String(format: "%.2f W", v)) }
                        if let v = i.smcPPBRW { InfoRow(label: "PPBR", value: String(format: "%.2f W", v)) }
                    }
                }
            }

            Divider()

            IOSDevicesSection(reader: iosReader)
                .onAppear { iosReader.refresh() }

            Divider()

            AndroidDevicesSection(reader: androidReader)
                .onAppear { androidReader.refresh() }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show % in menu bar", isOn: $showMenuBarPercent)
                Toggle("Show iPhone in menu bar", isOn: $showIPhoneMenuBar)
                Toggle("Show Android in menu bar", isOn: $showAndroidMenuBar)
            }
            .font(.caption)
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            HStack {
                Button("Refresh") {
                    reader.refresh()
                    iosReader.refresh()
                    androidReader.refresh()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PanelHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(PanelHeightPreferenceKey.self) { measuredContentHeight = $0 }
    }

    private func powerText(_ i: BatteryInfo) -> String {
        // Plugged in: show DC in (power drawn from the charger). On battery: show discharge power.
        // Prefer the SMC rails — they refresh ~1 Hz, so this row actually moves; the AdapterPower /
        // voltage×amperage fallbacks come from the battery gauge and only update every ~30–60 s.
        if i.externalConnected {
            if let dc = i.smcDCInW, dc > 0.05 {
                return String(format: "%.2f W (DC in)", dc)
            }
            if i.adapterPower > 0.05 {
                return String(format: "%.1f W (DC in)", i.adapterPower)
            }
            // Fallback for machines that don't expose AdapterPower (e.g. Intel): power flowing into the battery
            let charge = i.watts
            return charge > 0.05 ? String(format: "%.1f W (charging battery)", charge) : "—"
        }
        if let sys = i.smcSystemTotalW, sys > 0.05 {
            return String(format: "%.2f W (system)", sys)
        }
        let w = abs(i.watts)
        return w < 0.05 ? "0 W" : String(format: "%.1f W (discharging)", w)
    }

    private func statusText(_ i: BatteryInfo) -> String {
        if i.fullyCharged && i.externalConnected { return "Fully charged" }
        if i.isCharging {
            return (1..<65535).contains(i.timeToFull)
                ? "Full in ~\(fmtMinutes(i.timeToFull))" : "Charging"
        }
        if i.externalConnected { return "Plugged in, not charging" }
        return (1..<65535).contains(i.timeToEmpty)
            ? "~\(fmtMinutes(i.timeToEmpty)) remaining" : "On battery"
    }
}
