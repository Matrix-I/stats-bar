// StatsBarApp.swift — app entry point for StatsBar, a menu bar battery health app
// (coconutBattery-style).
//
// Requires : macOS 13 Ventura or later + Xcode Command Line Tools
//            (xcode-select --install)
//
// Build/run     :  ./build_app.sh        (compiles the whole Sources/ tree into StatsBar.app)
// Package .dmg  :  ./build_dmg.sh
//
// Data is read directly from the IOKit registry "AppleSmartBattery" (see BatteryReader) — the
// same source coconutBattery uses. No root needed, no kernel extension. Live power rails + fan
// speeds come from the AppleSMC user client (see SMC); iPhone/Android come over USB via
// libimobiledevice / adb (see IOSDeviceReader / AndroidDeviceReader).
//
// The menu-bar items (a Control Center hub plus one per metric) are built manually with
// NSStatusItem + NSPopover rather than SwiftUI's MenuBarExtra. MenuBarExtra can't enforce "only one
// popover open at a time": closing one item's window from the outside leaves that MenuBarExtra
// believing it's still presented, so the next click just toggles it shut (the classic two-click
// bug). Owning the NSPopovers ourselves lets us close the others cleanly — each popover's `isShown`
// stays truthful, so every switch is a single click.

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Readers live here (not as @StateObject on the App) since the status items, not a SwiftUI
    // scene, own the UI now. They keep polling for the whole app lifetime.
    private let batteryReader = BatteryReader()
    private let iosReader = IOSDeviceReader()
    private let androidReader = AndroidDeviceReader()
    private let networkReader = NetworkReader()
    private let cpuReader = CPUReader()
    private let memoryReader = MemoryReader()
    private let bluetoothReader = BluetoothReader()
    private let updater = Updater()

    /// One toggleable metric's menu-bar item: its status item, its detail popover, the UserDefaults
    /// key that shows/hides it, and — for the items whose glyph carries a live number — a builder
    /// that rebuilds that glyph each ~1 Hz tick. `liveImage` is nil for a static glyph (Bluetooth),
    /// which is set once at creation instead.
    private struct MetricItem {
        let statusItem: NSStatusItem
        let popover: NSPopover
        let visibilityKey: String
        let liveImage: (() -> NSImage?)?
    }

    /// A retained target for an NSControl's target/action that forwards to a Swift closure. NSControl
    /// holds its `target` weakly, so instances must be kept alive by `buttonActions` — otherwise the
    /// action would deallocate immediately and clicks would do nothing.
    private final class ButtonAction: NSObject {
        private let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func fire() { handler() }
    }

    /// The five toggleable metrics, keyed by StatMetric. Built in applicationDidFinishLaunching, then
    /// driven uniformly (toggle / presentDetail / refreshLabels) instead of one ivar + one @objc
    /// selector each. The Control Center is kept separate — it's never hidden and its glyph is static.
    private var metricItems: [StatMetric: MetricItem] = [:]
    private var buttonActions: [ButtonAction] = []

    private var controlCenterItem: NSStatusItem!
    private let controlCenterPopover = NSPopover()

    private var allPopovers: [NSPopover] {
        [controlCenterPopover] + StatMetric.allCases.compactMap { metricItems[$0]?.popover }
    }

    /// Refreshes the live status-item glyphs ~1 Hz (cheap to rebuild; the readers update at that rate
    /// anyway). Also the hook for menu-bar toggle changes to take effect within a second.
    private var labelTimer: Timer?
    /// Fires on clicks outside the app so an open popover dismisses like a normal menu-bar popover.
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app menu (the .app bundle also sets LSUIElement).
        NSApp.setActivationPolicy(.accessory)

        // The Control Center is created first (leftmost) and is the one item with no visibility
        // toggle — it's the always-present hub for turning the others back on. Its glyph carries no
        // live number, so it's set once here rather than rebuilt each second in refreshLabels.
        configure(popover: controlCenterPopover,
                  root: ControlCenterView(battery: batteryReader, cpu: cpuReader, memory: memoryReader,
                                          network: networkReader, bluetooth: bluetoothReader,
                                          updater: updater,
                                          openDetail: { [weak self] metric in self?.presentDetail(metric) },
                                          checkForUpdates: { [weak self] in
                                              self?.closeAll()
                                              self?.updater.checkForUpdates()
                                          }))
        controlCenterItem = makeStatusItem(image: controlCenterMenuBarImage()) { [weak self] in
            guard let self else { return }
            self.toggle(self.controlCenterPopover, item: self.controlCenterItem)
        }

        // The five toggleable metrics, in menu-bar order (StatMetric's declaration order). Each pairs
        // its reader-typed detail view with the glyph builder refreshLabels rebuilds each tick; the
        // Bluetooth glyph is static, so it's passed as a one-shot image with no live builder.
        addMetric(.battery, key: "showBatteryItem",
                  root: BatteryDetailView(reader: batteryReader, iosReader: iosReader, androidReader: androidReader),
                  liveImage: { [weak self] in self?.currentBatteryImage() })
        addMetric(.cpu, key: "showCPUItem",
                  root: CPUDetailView(reader: cpuReader),
                  liveImage: { [weak self] in self.map { symbolPercentMenuBarImage(symbol: "cpu", percent: Int($0.cpuReader.info.usagePercent.rounded())) } })
        addMetric(.memory, key: "showMemoryItem",
                  root: MemoryDetailView(reader: memoryReader),
                  liveImage: { [weak self] in self.map { symbolPercentMenuBarImage(symbol: "memorychip", percent: Int($0.memoryReader.info.usagePercent.rounded())) } })
        addMetric(.network, key: "showNetworkItem",
                  root: NetworkDetailView(reader: networkReader),
                  liveImage: { [weak self] in self.map { networkMenuBarImage(up: $0.networkReader.info.uploadRate, down: $0.networkReader.info.downloadRate) } })
        addMetric(.bluetooth, key: "showBluetoothItem",
                  root: BluetoothDetailView(reader: bluetoothReader),
                  staticImage: bluetoothMenuBarImage())

        refreshLabels()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshLabels() }
        RunLoop.main.add(t, forMode: .common)
        labelTimer = t

        // A global monitor sees only clicks in OTHER apps / the desktop, never our own popover's
        // interior or our status buttons — exactly the "clicked away" case that should dismiss.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.closeAll()
        }
    }

    /// Hosts a SwiftUI detail view in a popover. `.applicationDefined` (not `.transient`) so the
    /// system never auto-dismisses it behind our back — we do all closing — which is what keeps the
    /// one-click switching deterministic. `.preferredContentSize` lets the SwiftUI content drive the
    /// popover's size the same way it drove the MenuBarExtra window.
    private func configure<Root: View>(popover: NSPopover, root: Root) {
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = host
    }

    /// Creates a variable-length status item wired to `onClick` through a retained closure trampoline
    /// (so items are built in a loop rather than one @objc selector each), optionally carrying a
    /// static glyph for items whose image never changes.
    private func makeStatusItem(image: NSImage? = nil, onClick: @escaping () -> Void) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let action = ButtonAction(onClick)
        buttonActions.append(action)
        item.button?.target = action
        item.button?.action = #selector(ButtonAction.fire)
        if let image { item.button?.image = image }
        return item
    }

    /// Builds one toggleable metric's popover + status item and records it in `metricItems`.
    private func addMetric<Root: View>(_ metric: StatMetric, key: String, root: Root,
                                       staticImage: NSImage? = nil,
                                       liveImage: (() -> NSImage?)? = nil) {
        let popover = NSPopover()
        configure(popover: popover, root: root)
        let statusItem = makeStatusItem(image: staticImage) { [weak self] in self?.toggleMetric(metric) }
        metricItems[metric] = MetricItem(statusItem: statusItem, popover: popover,
                                         visibilityKey: key, liveImage: liveImage)
    }

    private func toggleMetric(_ metric: StatMetric) {
        guard let m = metricItems[metric] else { return }
        toggle(m.popover, item: m.statusItem)
    }

    /// Opens a metric's detail popover from the Control Center overview. Anchors to that metric's
    /// own menu-bar item when it's visible, otherwise to the Control Center button — so tapping a
    /// row works even for an item the user has hidden. Mirrors `toggle`'s single-popover + activate
    /// sequencing so the opened popover is focused and every other one is closed cleanly.
    private func presentDetail(_ metric: StatMetric) {
        guard let m = metricItems[metric] else { return }
        let anchor: NSStatusItem = m.statusItem.isVisible ? m.statusItem : controlCenterItem
        guard let button = anchor.button else { return }

        for other in allPopovers where other !== m.popover { other.performClose(nil) }
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        m.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.async {
            m.popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func toggle(_ popover: NSPopover, item: NSStatusItem) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Single-popover rule — close every other one first, cleanly, so switching stays one-click.
        for other in allPopovers where other !== popover { other.performClose(nil) }
        guard let button = item.button else { return }

        // An accessory app isn't the active app, so a freshly shown popover opens *unfocused* — its
        // controls wouldn't respond until you clicked into it. Activate the app FIRST (before show,
        // using the cooperative-activation API on macOS 14+ where the ignoringOtherApps variant is
        // deprecated and unreliable), then show, then key the popover window on the next run-loop
        // turn — by then activation has taken effect, so makeKey() actually sticks.
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.async {
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func closeAll() {
        for p in allPopovers where p.isShown { p.performClose(nil) }
    }

    private func refreshLabels() {
        // Per-item visibility + live glyphs, driven off the Control Center's "show<Item>Item" toggles.
        // Read the visibility flag the same lenient way as the battery glyph flags (absent key ⇒
        // shown) so a fresh install shows every item; setting isVisible is a no-op when unchanged, so
        // doing it here just makes a toggle take effect within ~1 s. The Control Center is never hidden.
        //
        // We intentionally do NOT close a hidden item's popover: the overview deliberately opens a
        // hidden metric's detail anchored to the hub button (see presentDetail), and closing it on the
        // next tick would defeat that. A hide never coincides with the item's own popover being open —
        // the single-popover rule closed it the moment the Control Center opened — so there's nothing
        // to close. Items with a live glyph (Battery / CPU / RAM / Network) get it rebuilt here; the
        // static Bluetooth glyph (liveImage == nil) was set once at creation.
        for metric in StatMetric.allCases {
            guard let m = metricItems[metric] else { continue }
            m.statusItem.isVisible = UserDefaults.standard.object(forKey: m.visibilityKey) as? Bool ?? true
            if let image = m.liveImage?() { m.statusItem.button?.image = image }
        }
    }

    /// Rebuilds the battery glyph, mirroring the old MenuBarLabel logic: a combined Mac+phone glyph
    /// when the iPhone/Android menu-bar toggle is on and a device is readable, otherwise the plain
    /// Mac battery. iPhone wins over Android when both are present, to keep the item from growing a
    /// third glyph.
    private func currentBatteryImage() -> NSImage {
        let defaults = UserDefaults.standard
        let showPercent = defaults.object(forKey: "showMenuBarPercent") as? Bool ?? true
        let showIPhone = defaults.bool(forKey: "showIPhoneMenuBar")
        let showAndroid = defaults.bool(forKey: "showAndroidMenuBar")
        let info = batteryReader.info
        let macPct = Int(info.chargePercent.rounded())

        if showIPhone, let ios = iosReader.devices.first, let cp = ios.chargePercent {
            return dualMenuBarImage(macPct: macPct, macCharging: info.isPluggedIn,
                                    phonePct: Int(cp.rounded()), phoneCharging: ios.isPluggedIn,
                                    phoneSymbol: "iphone", showPercent: showPercent)
        }
        if showAndroid, let android = androidReader.devices.first, let level = android.levelPercent {
            return dualMenuBarImage(macPct: macPct, macCharging: info.isPluggedIn,
                                    phonePct: level, phoneCharging: android.isPluggedIn,
                                    phoneSymbol: "candybarphone", showPercent: showPercent)
        }
        return batteryMenuBarImage(level: info.chargePercent / 100,
                                   charging: info.isPluggedIn,
                                   percent: showPercent ? macPct : nil)
    }
}

@main
struct StatsBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No visible scene — the UI is the NSStatusItems built in AppDelegate. Settings gives the
        // App a valid (empty, never-shown) scene body.
        Settings { EmptyView() }
    }
}
