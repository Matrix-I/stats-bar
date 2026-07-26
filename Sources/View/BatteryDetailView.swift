// BatteryDetailView.swift — the popover shown when the menu-bar item is clicked: live fans,
// the Mac battery + health + power readout, the iPhone/Android sections, settings toggles, and
// the height-management machinery that lets the popover scroll instead of overflowing the screen.

import SwiftUI
import AppKit

/// Reports the true (unclipped) height of the ScrollView's content, so the popover can be sized
/// to `min(content height, cap)` instead of relying on ScrollView's own ideal size — which SwiftUI
/// reports as ~0 in an auto-sizing container like MenuBarExtra(.window), making the window vanish.
private struct PanelHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Take the max, not the last value: the background GeometryReader emits a spurious 0 during
        // an early layout pass alongside the real content height, and `value = nextValue()` let that
        // 0 clobber the real measurement — leaving measuredContentHeight stuck at 0 so the popover
        // never switched to the scrolling branch. max() keeps the real height; each layout pass
        // recomputes from scratch, so it still tracks the content shrinking.
        value = max(value, nextValue())
    }
}

/// Height of the pinned footer (menu-bar settings + Refresh/Quit), measured the same way as the
/// scroll content so it can be subtracted from the cap. Same max()-not-last reasoning as above.
private struct FooterHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
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

    // Show-more state for the iPhone / Android sections. Owned HERE — the same view that renders those
    // sections (see iPhoneSection / androidSection) and measures the popover height — exactly like the
    // Mac toggles above.
    //
    // Both use @AppStorage, NOT @State, and that is the whole fix for the expand "giật": an @AppStorage
    // write propagates back through UserDefaults on its own publish cycle, OUTSIDE the withAnimation
    // transaction, so SwiftUI resizes the popover in a single instant step (frame-analysis: 0 ramp frames,
    // identical to the Mac "Battery" toggle). A @State toggle animates the height over ~9 frames, and the
    // self-measuring height machinery (GeometryReader → PanelHeightPreferenceKey → measuredContentHeight)
    // stutters during that ramp — overshooting and reversing for a frame. So the clean-looking Mac toggle
    // is clean precisely BECAUSE @AppStorage skips the animation; matching it here removes the jitter.
    @AppStorage("showIPhoneFullDetails") private var showIPhoneFullDetails = false
    @AppStorage("showAndroidFullDetails") private var showAndroidFullDetails = false

    // Read by TemperatureAlerter (same key, same default) to decide whether to warn on a hot iPhone.
    @AppStorage("alertHotIPhone") private var alertHotIPhone = true

    // visibleFrame height of the screen the popover is *actually* shown on. MenuBarExtra can open
    // the popover on any display (in a multi-monitor setup it follows the active menu bar, not
    // necessarily the primary screen), so WindowVisibilityReporter feeds us the real one via
    // `window.screen`. Seeded with a sensible menu-bar-screen guess for the very first layout pass.
    @State private var panelScreenHeight: CGFloat = BatteryDetailView.initialScreenHeight

    // Fraction of the shown-on screen's height the popover may occupy before it starts scrolling.
    private static let panelHeightFraction: CGFloat = 0.9

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

    // Measured height of the pinned footer (settings toggles + Refresh/Quit). Subtracted from the
    // cap so the scroll area never grows over it. Starts at 0 so the first pass isn't scrolled.
    @State private var footerHeight: CGFloat = 0

    // The scroll area may fill up to the cap minus whatever the pinned footer needs. Measured, not
    // estimated, so it tracks the footer's real height across control sizes / font settings.
    private var maxScrollHeight: CGFloat { max(120, maxPanelHeight - footerHeight) }

    var body: some View {
        // Render un-scrolled by default (identical to the plain auto-sizing VStack this used to
        // be) so the very first layout pass always has a well-defined size and the popover shows.
        // Only once we've measured the scrollable content taller than the room left by the footer
        // do we switch to a ScrollView with a concrete fixed height — never an ambiguous/ideal-only
        // constraint, which is what made the window vanish before. The footer (menu-bar settings +
        // Refresh/Quit) always sits OUTSIDE the ScrollView so it stays pinned and reachable.
        Group {
            if measuredContentHeight > maxScrollHeight {
                VStack(spacing: 0) {
                    ScrollView { scrollableContent.background(OverlayScrollerConfigurator()) }
                        .frame(height: maxScrollHeight)
                    footer
                }
            } else {
                VStack(spacing: 0) {
                    scrollableContent
                    footer
                }
            }
        }
        .frame(width: 300)
        .background(WindowVisibilityReporter(
            onChange: { open in
                reader.setPanelOpen(open)
                // Tell the phone readers this popover (their only consumer) is open, so they poll at
                // ~1 Hz while it's visible and drop to a slow keep-warm when it's closed and the phone
                // menu-bar glyph is off. We deliberately do NOT force a read on open here: a slow
                // libimobiledevice/adb read landing at an unpredictable moment could snap a section's
                // expand animation, so the cache is shown immediately and the next ~1 Hz tick refreshes.
                // The Refresh button still forces a read.
                iosReader.setPanelOpen(open)
                androidReader.setPanelOpen(open)
            },
            onScreenHeight: { h in if h > 0 { panelScreenHeight = h } }
        ))
    }

    @ViewBuilder
    private var scrollableContent: some View {
        let i = reader.info
        VStack(alignment: .leading, spacing: 12) {

            // 🌀 Fan speeds from the SMC (live, ~1 Hz) — pinned above the battery readout.
            // Skipped entirely on fanless Macs (e.g. MacBook Air), so the battery header stays first there.
            if !i.fans.isEmpty {
                SectionCaption("🌀 Fans (live)")
                VStack(spacing: 6) {
                    ForEach(Array(i.fans.enumerated()), id: \.offset) { idx, rpm in
                        InfoRow(label: i.fans.count > 1 ? "Fan \(idx + 1)" : "Fan",
                                value: "\(Int(rpm.rounded())) rpm")
                    }
                }
            }

            // Header — the "🔋 Battery" title is centred on the line; the device name and the
            // show-more toggle are anchored to the trailing edge, overlaid on the same row (same
            // centred-title / right-aligned-control layout SectionCaption uses).
            ZStack {
                Text("🔋 Battery").font(.headline)
                HStack {
                    Spacer()
                    Text(i.deviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ShowMoreButton(isOn: $showMacFullDetails)
                }
            }

            // Current charge
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Current charge")
                        .font(.system(size: 14)).foregroundStyle(.white)
                    Spacer()
                    Text(String(format: "%.1f%%", i.chargePercent))
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                }
                BarView(pct: i.chargePercent, color: .blue)
                Text("\(i.currentCapacity) / \(i.maxCapacity) mAh")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }

            // Maximum Capacity — macOS's own battery-health figure (System Information / Battery
            // Health), read via system_profiler in BatteryReader. Falls back to the raw
            // full-charge-vs-design fraction only until the first read lands.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Maximum Capacity")
                        .font(.system(size: 14)).foregroundStyle(.white)
                    Spacer()
                    Text(String(format: "%.0f%%", i.displayMaximumCapacity))
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(healthColor(i.displayMaximumCapacity))
                }
                BarView(pct: i.displayMaximumCapacity, color: healthColor(i.displayMaximumCapacity))
                Text("\(i.maxCapacity) / \(i.designCapacity) mAh · raw \(String(format: "%.1f%%", i.healthPercent))")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
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
                SectionCaption("⚡ Power (live)") {
                    ShowMoreButton(isOn: $showMacPowerLiveDetails)
                }
                VStack(alignment: .leading, spacing: 6) {
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

            // iPhone / Android built EXACTLY like the Mac "Battery" block above: a single value read
            // inline, no ForEach, no separate row View. The old ForEach over the 1 Hz-replaced
            // `iosReader.devices` array rebuilt its rows on every reader tick, and a tick landing during
            // the 0.15 s expand snapped the animation — that was the stutter. Reading one device inline
            // (like the Mac block reads `reader.info`) can't be interrupted that way.
            iPhoneSection
            androidSection
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

    // Time-only for a reading captured today; date + time once it's from an earlier day, so a health
    // figure that is actually days old isn't misread as a same-day reading. (Ported from the old
    // IOSDeviceRow when the iPhone block was inlined to match the Mac battery block.)
    private static func readingStamp(_ at: Date) -> String {
        Calendar.current.isDateInToday(at)
            ? at.formatted(date: .omitted, time: .shortened)
            : at.formatted(date: .abbreviated, time: .shortened)
    }

    // 📱 iPhone / iPad — built to mirror the Mac "Battery" block EXACTLY: one value read inline
    // (`iosReader.devices.first`, the primary connected iPhone), its rows written straight into this
    // VStack with `if showIPhoneFullDetails` toggling the detail rows — no ForEach, no separate row
    // View. The previous ForEach over the 1 Hz-replaced `iosReader.devices` array rebuilt its row
    // views on every reader tick; a tick landing mid-expand snapped the 0.15 s animation. An inline
    // single-value read (exactly how the Mac block reads `reader.info`) can't be interrupted that way.
    // Only the primary device is shown now — same single-battery shape as the Mac block.
    @ViewBuilder
    private var iPhoneSection: some View {
        let device = iosReader.devices.first
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("📱 iPhone / iPad (USB / Wi-Fi)") {
                if device != nil {
                    ShowMoreButton(isOn: $showIPhoneFullDetails)
                }
            }

            if iosReader.toolsMissing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Missing libimobiledevice.").font(.caption2).foregroundStyle(.orange)
                    Text("brew install libimobiledevice")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else if let status = iosReader.statusMessage {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            } else if let device {
                // The single device's rows, written inline — mirrors the Mac battery block's inline rows.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(device.name).font(.caption).fontWeight(.semibold).lineLimit(1)
                        Spacer()
                        let sub = [device.model.isEmpty ? nil : device.model,
                                   device.iosVersion.isEmpty ? nil : "iOS \(device.iosVersion)"]
                            .compactMap { $0 }.joined(separator: " · ")
                        if !sub.isEmpty {
                            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }

                    if device.isNetwork {
                        Text("📶 Connected over Wi-Fi (no USB data connection)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    if device.isStale {
                        Text("⟳ last known data — connection reconnecting")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    if device.isLocked {
                        if device.maxCapacity != nil, let at = device.capturedAt {
                            Text("🔒 Battery health from last reading (\(Self.readingStamp(at))) — unlock the iPhone to refresh.")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("🔒 Unlock the iPhone to read battery health.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    if let err = device.errorMessage {
                        Text(err).font(.caption2).foregroundStyle(.red)
                    } else if device.chargePercent == nil && device.maximumCapacityPercent == nil {
                        if !device.isLocked {
                            Text("⚠ Couldn't read health data — unlock the device + Trust, then tap Refresh.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    } else {
                        // Same block layout, fonts, mAh subline, and 12 pt group spacing as the Mac
                        // battery card above, so the two cards read identically.
                        VStack(alignment: .leading, spacing: 12) {
                            if let cp = device.chargePercent {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("Current charge").font(.system(size: 14)).foregroundStyle(.white)
                                        Spacer()
                                        Text(String(format: "%.1f%%", cp))
                                            .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                                    }
                                    BarView(pct: cp, color: .blue)
                                    if let cur = device.currentCapacity, let max = device.maxCapacity {
                                        Text("\(cur) / \(max) mAh")
                                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                            }
                            if let mc = device.maximumCapacityPercent {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("Maximum Capacity").font(.system(size: 14)).foregroundStyle(.white)
                                        Spacer()
                                        Text(String(format: "%.0f%%", mc))
                                            .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                                            .foregroundStyle(healthColor(mc))
                                    }
                                    BarView(pct: mc, color: healthColor(mc))
                                    if device.nominalChargeCapacity != nil, let raw = device.rawHealthPercent {
                                        Text(String(format: "raw %.1f%% (vs design)", raw))
                                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                            }
                            VStack(spacing: 6) {
                                if let max = device.maxCapacity {
                                    InfoRow(label: "Full charge capacity", value: "\(max) mAh")
                                }
                                if let design = device.designCapacity {
                                    InfoRow(label: "Design capacity", value: "\(design) mAh")
                                }
                                if let cc = device.cycleCount {
                                    InfoRow(label: "Cycle count", value: "\(cc)")
                                }
                                if showIPhoneFullDetails {
                                    if let t = device.temperatureC {
                                        InfoRow(label: "Temperature", value: String(format: "%.1f °C", t))
                                    }
                                    if let v = device.voltageV {
                                        InfoRow(label: "Voltage", value: String(format: "%.2f V", v))
                                    }
                                    if device.isCharging, let w = device.watts, w > 0.05 {
                                        InfoRow(label: "Charging with", value: String(format: "%.1f W", w))
                                    }
                                    if device.externalConnected {
                                        InfoRow(label: "Status",
                                                value: device.isCharging ? "Charging"
                                                    : (device.fullyCharged ? "Fully charged" : "Plugged in, not charging"))
                                    }
                                    if !device.serial.isEmpty {
                                        InfoRow(label: "Serial", value: device.serial)
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            } else {
                Text("No devices connected.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        // No .onAppear refresh: the background timer keeps `iosReader.devices` warm, so this just shows
        // the cache. Avoids a slow read landing mid-animation (see the WindowVisibilityReporter note).
    }

    // 🤖 Android — inline for the same reason as iPhoneSection (was an AndroidDevicesSection child that
    // observed androidReader on its own transaction).
    @ViewBuilder
    private var androidSection: some View {
        let hasDevices = !androidReader.toolsMissing && androidReader.statusMessage == nil && !androidReader.devices.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("🤖 Android (USB)") {
                if hasDevices {
                    ShowMoreButton(isOn: $showAndroidFullDetails)
                }
            }

            if androidReader.toolsMissing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Missing adb.").font(.caption2).foregroundStyle(.orange)
                    Text("brew install --cask android-platform-tools")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else if let status = androidReader.statusMessage {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            } else if androidReader.devices.isEmpty {
                Text("No devices connected.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(androidReader.devices) { device in
                        AndroidDeviceRow(device: device, showFullDetails: showAndroidFullDetails)
                        if device.id != androidReader.devices.last?.id { Divider() }
                    }
                }
            }
        }
        // No .onAppear refresh — background timer keeps the cache warm; opening just shows it.
    }

    // Pinned below the scroll area — never scrolls away, so the menu-bar toggles and Refresh/Quit
    // are always reachable no matter how many devices/sections push the content past the cap.
    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show % in menu bar", isOn: $showMenuBarPercent)
                Toggle("Show iPhone in menu bar", isOn: $showIPhoneMenuBar)
                Toggle("Show Android in menu bar", isOn: $showAndroidMenuBar)
                Toggle("Alert when iPhone battery is hot (39°C)", isOn: $alertHotIPhone)
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
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: FooterHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(FooterHeightPreferenceKey.self) { footerHeight = $0 }
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

/// The compact "slider.horizontal.3" pill that expands/collapses a section's detail rows. One shared
/// definition for the Mac / Power / iPhone / Android sections so they stay visually identical — before
/// this it was copy-pasted verbatim four times, differing only in the bound flag. `isOn` binds to the
/// section's show-more @AppStorage flag; the withAnimation is kept here so every site animates the same
/// way (the @AppStorage write still propagates on its own publish cycle, outside this transaction — see
/// the note on showIPhoneFullDetails for why that matters to the resize animation).
private struct ShowMoreButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isOn.toggle()
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .padding(4)
                .background(
                    Circle().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .help(isOn ? "Show less" : "Show more")
    }
}
