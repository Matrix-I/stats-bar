// ControlCenterView.swift — the Control Center popover: a single "StatsBar" hub that both shows a
// compact at-a-glance overview of every metric AND manages the app. It's driven by its own always-
// visible menu-bar item (see controlCenterMenuBarImage / AppDelegate), so it's the one item that
// can never be hidden — the place you go to turn the others back on.
//
// Three sections:
//   • Overview      — one tappable row per metric (Battery / CPU / RAM / Network / Bluetooth); a tap
//                     closes this popover and opens that metric's own detail popover (openDetail).
//   • Menu bar items — a switch per metric, backed by "show<Item>Item" UserDefaults keys that
//                     AppDelegate.refreshLabels() reads ~1 Hz to drive each NSStatusItem.isVisible.
//   • General       — Launch at login, backed by SMAppService via LoginItem.
//
// It observes all five readers so the overview stays live, and forwards the popover's open/closed
// state to every reader's setPanelOpen so they poll at their faster cadence while it's showing
// (Bluetooth in particular only polls while a panel is open).

import SwiftUI
import AppKit

/// The metrics the overview can open. AppDelegate maps each to its popover + anchor button, and
/// iterates `allCases` (declaration order = menu-bar order) to build and refresh the items.
enum StatMetric: CaseIterable { case battery, cpu, memory, network, bluetooth }

struct ControlCenterView: View {
    @ObservedObject var battery: BatteryReader
    @ObservedObject var cpu: CPUReader
    @ObservedObject var memory: MemoryReader
    @ObservedObject var network: NetworkReader
    @ObservedObject var bluetooth: BluetoothReader

    /// Sparkle updater — backs the "Check for updates" button and the automatic-check toggle.
    let updater: Updater

    /// Opens a metric's own detail popover; supplied by AppDelegate.
    let openDetail: (StatMetric) -> Void

    /// Closes this popover and starts a user-initiated Sparkle check; supplied by AppDelegate.
    let checkForUpdates: () -> Void

    /// The app's marketing version (CFBundleShortVersionString), shown top-right in the header — e.g.
    /// "v2.2.0". Read from the bundle so it tracks build_app.sh's version bump with no code change.
    /// A `static let` (computed once for the process) rather than a computed property: the version is
    /// constant at runtime, and the hub observes all five readers so its body re-evaluates often — no
    /// need to redo the Bundle lookup on every eval.
    private static let appVersion: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v.map { "v\($0)" } ?? ""
    }()

    // Per-item menu-bar visibility. Defaults match AppDelegate's `object(forKey:) as? Bool ?? true`
    // reads, so a fresh install shows every item until the user turns one off here.
    @AppStorage("showBatteryItem")   private var showBattery = true
    @AppStorage("showCPUItem")       private var showCPU = true
    @AppStorage("showMemoryItem")    private var showMemory = true
    @AppStorage("showNetworkItem")   private var showNetwork = true
    @AppStorage("showBluetoothItem") private var showBluetooth = true

    /// Cached so the "Launch at login" Toggle's Binding.get doesn't call SMAppService.mainApp.status
    /// (a synchronous ServiceManagement lookup) on every body eval — the hub re-evaluates several
    /// times a second while open. Seeded once, refreshed when the popover opens (the only moment an
    /// external change via System Settings ▸ Login Items matters), and written by the setter.
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("StatsBar")
                .font(.system(size: 19.5, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)
                .overlay(alignment: .trailing) {
                    Text(Self.appVersion)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

            overview

            SectionCaption("MENU BAR ITEMS")
            menuBarToggles

            SectionCaption("GENERAL")
            switchRow("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: {
                    LoginItem.setEnabled($0)
                    // Reconcile with the REAL status, not the requested value: setEnabled swallows a
                    // failed/blocked register()/unregister() (or the OS may return .requiresApproval),
                    // so re-reading snaps the toggle back to the truth instead of showing a false ON.
                    launchAtLogin = LoginItem.isEnabled
                }
            ))

            switchRow("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.automaticallyChecks = $0 }
            ))

            Button(action: checkForUpdates) {
                Text("Check for updates…").font(.system(size: 13))
            }
            .buttonStyle(.link)

            Divider()

            HStack {
                Button("Refresh") { refreshAll() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowVisibilityReporter(onChange: { open in
            if open { launchAtLogin = LoginItem.isEnabled }   // catch an external Login Items change
            setPanelOpen(open)
        }))
    }

    // MARK: Overview

    /// The Bluetooth overview glyph is a fixed, state-independent rune (SF Symbols ships none), so
    /// bake the template NSImage once instead of re-allocating it on every `overview` re-evaluation —
    /// which happens several times per second while the popover is open, as all five observed readers
    /// publish at ~1 Hz.
    private static let bluetoothGlyph = bluetoothMenuBarImage()

    @ViewBuilder
    private var overview: some View {
        VStack(spacing: 6) {
            OverviewRow(icon: .symbol(batterySymbol, batteryTint(batteryPercent)),
                        label: "Battery", value: "\(pct(batteryPercent))%",
                        valueColor: batteryTint(batteryPercent),
                        charging: battery.info.isPluggedIn) { openDetail(.battery) }

            OverviewRow(icon: .symbol("cpu", .secondary),
                        label: "CPU", value: "\(pct(cpu.info.usagePercent))%",
                        valueColor: usageTint(cpu.info.usagePercent)) { openDetail(.cpu) }

            OverviewRow(icon: .symbol("memorychip", .secondary),
                        label: "RAM", value: "\(pct(memory.info.usagePercent))%",
                        valueColor: usageTint(memory.info.usagePercent)) { openDetail(.memory) }

            OverviewRow(icon: .symbol("arrow.up.arrow.down", .secondary),
                        label: "Network", value: networkValue,
                        valueColor: .white) { openDetail(.network) }

            OverviewRow(icon: .image(Self.bluetoothGlyph),
                        label: "Bluetooth", value: bluetoothValue,
                        valueColor: bluetoothReady ? .white : .secondary) { openDetail(.bluetooth) }
        }
    }

    // MARK: Menu-bar toggles

    private var menuBarToggles: some View {
        VStack(spacing: 4) {
            switchRow("Battery", isOn: $showBattery)
            switchRow("CPU", isOn: $showCPU)
            switchRow("RAM", isOn: $showMemory)
            switchRow("Network", isOn: $showNetwork)
            switchRow("Bluetooth", isOn: $showBluetooth)
        }
    }

    /// A settings row: label on the left, switch pushed to the right edge (Spacer between), so a
    /// column of switches aligns down the right regardless of label width — matching the overview
    /// rows, whose values are right-aligned the same way. Used for both settings sections.
    private func switchRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer(minLength: 12)
            Toggle(label, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.green)
        }
    }

    // MARK: Derived overview values

    private var batteryPercent: Double { battery.info.chargePercent }

    /// A level-matched battery glyph. SF Symbols only ships a `.bolt` variant for the full battery,
    /// so we never swap the whole glyph for it while charging (that would show a "full" battery at
    /// any level) — the charging bolt is drawn as a small overlay by OverviewRow instead.
    private var batterySymbol: String {
        switch pct(batteryPercent) {
        case ..<13:  return "battery.0"
        case ..<38:  return "battery.25"
        case ..<63:  return "battery.50"
        case ..<88:  return "battery.75"
        default:     return "battery.100"
        }
    }

    private var networkValue: String {
        "↓\(fmtRate(network.info.downloadRate))  ↑\(fmtRate(network.info.uploadRate))"
    }

    /// Whether the Bluetooth readout is a real, powered-on state (vs still loading or off) — drives
    /// the value colour so a pending/off state reads muted rather than as an assertion.
    private var bluetoothReady: Bool { bluetooth.info.hasLoaded && bluetooth.info.poweredOn }

    private var bluetoothValue: String {
        // Mirror the Bluetooth tab: the default poweredOn=false is indistinguishable from a genuine
        // "off", so show a neutral placeholder until the first read lands rather than asserting "Off".
        guard bluetooth.info.hasLoaded else { return "…" }
        guard bluetooth.info.poweredOn else { return "Off" }
        let n = bluetooth.info.connected.count
        return n == 0 ? "None" : "\(n) device\(n == 1 ? "" : "s")"
    }

    private func pct(_ v: Double) -> Int { Int(v.rounded()) }

    /// Usage ramp shared with the CPU/RAM tabs: green under 70%, orange under 85%, red above.
    private func usageTint(_ p: Double) -> Color { p < 70 ? .green : (p < 85 ? .orange : .red) }

    /// Battery ramp: red at/under 20%, orange at/under 40%, green above.
    private func batteryTint(_ p: Double) -> Color { p <= 20 ? .red : (p <= 40 ? .orange : .green) }

    // MARK: Actions

    /// The five overview readers seen through their shared control surface, so Refresh and the
    /// panel-open forwarding below drive them in one loop instead of naming each by hand. (Reading
    /// each reader's typed `.info` still goes through the @ObservedObject properties above.)
    private var readers: [any MetricReader] { [battery, cpu, memory, network, bluetooth] }

    private func refreshAll() { readers.forEach { $0.refresh() } }

    /// Forward the popover's visibility to every reader so they poll live while it's open (and drop
    /// back to their idle cadence when it closes). Bluetooth only polls while a panel is open, so
    /// this is what keeps its device count current in the overview.
    private func setPanelOpen(_ open: Bool) {
        readers.forEach { $0.setPanelOpen(open) }
    }
}

/// One tappable overview row: an icon, the metric name, its live value (colour-coded), and a
/// chevron cueing that tapping opens the full tab.
private struct OverviewRow: View {
    enum Icon {
        case symbol(String, Color)   // SF Symbol name + tint
        case image(NSImage)          // a baked template glyph (e.g. the Bluetooth rune)
    }

    let icon: Icon
    let label: String
    let value: String
    let valueColor: Color
    var charging: Bool = false   // overlays a small bolt on the icon (battery while plugged in)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                iconView.frame(width: 20, alignment: .center)
                Text(label).foregroundStyle(.white)
                Spacer(minLength: 8)
                Text(value)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
    }

    @ViewBuilder
    private var iconView: some View {
        baseIcon
            .overlay(alignment: .bottomTrailing) {
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.yellow)
                        .offset(x: 3, y: 1)
                }
            }
    }

    @ViewBuilder
    private var baseIcon: some View {
        switch icon {
        case let .symbol(name, color):
            Image(systemName: name)
                .font(.system(size: 14))
                .foregroundStyle(color)
        case let .image(img):
            Image(nsImage: img)
                .renderingMode(.template)
                .foregroundStyle(.secondary)
        }
    }
}
