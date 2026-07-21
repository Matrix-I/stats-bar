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
// The two menu-bar items (Battery + Network) are built manually with NSStatusItem + NSPopover rather
// than SwiftUI's MenuBarExtra. MenuBarExtra can't enforce "only one popover open at a time": closing
// one item's window from the outside leaves that MenuBarExtra believing it's still presented, so the
// next click just toggles it shut (the classic two-click bug). Owning the NSPopovers ourselves lets
// us close the other one cleanly — its `isShown` stays truthful, so every switch is a single click.

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

    private var controlCenterItem: NSStatusItem!
    private var batteryItem: NSStatusItem!
    private var networkItem: NSStatusItem!
    private var cpuItem: NSStatusItem!
    private var memoryItem: NSStatusItem!
    private var bluetoothItem: NSStatusItem!
    private let controlCenterPopover = NSPopover()
    private let batteryPopover = NSPopover()
    private let networkPopover = NSPopover()
    private let cpuPopover = NSPopover()
    private let memoryPopover = NSPopover()
    private let bluetoothPopover = NSPopover()

    private var allPopovers: [NSPopover] { [controlCenterPopover, batteryPopover, networkPopover, cpuPopover, memoryPopover, bluetoothPopover] }

    /// Refreshes the two status-item glyphs ~1 Hz (cheap to rebuild; the readers update at that rate
    /// anyway). Also the hook for menu-bar toggle changes to take effect within a second.
    private var labelTimer: Timer?
    /// Fires on clicks outside the app so an open popover dismisses like a normal menu-bar popover.
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app menu (the .app bundle also sets LSUIElement).
        NSApp.setActivationPolicy(.accessory)

        configure(popover: controlCenterPopover,
                  root: ControlCenterView(battery: batteryReader, cpu: cpuReader, memory: memoryReader,
                                          network: networkReader, bluetooth: bluetoothReader,
                                          updater: updater,
                                          openDetail: { [weak self] metric in self?.presentDetail(metric) },
                                          checkForUpdates: { [weak self] in
                                              self?.closeAll()
                                              self?.updater.checkForUpdates()
                                          }))
        configure(popover: batteryPopover,
                  root: BatteryDetailView(reader: batteryReader, iosReader: iosReader, androidReader: androidReader))
        configure(popover: networkPopover, root: NetworkDetailView(reader: networkReader))
        configure(popover: cpuPopover, root: CPUDetailView(reader: cpuReader))
        configure(popover: memoryPopover, root: MemoryDetailView(reader: memoryReader))
        configure(popover: bluetoothPopover, root: BluetoothDetailView(reader: bluetoothReader))

        // The Control Center is created first (leftmost) and is the one item with no visibility
        // toggle — it's the always-present hub for turning the others back on. Its glyph carries no
        // live number, so it's set once here rather than rebuilt each second in refreshLabels.
        controlCenterItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        controlCenterItem.button?.target = self
        controlCenterItem.button?.action = #selector(toggleControlCenter)
        controlCenterItem.button?.image = controlCenterMenuBarImage()

        batteryItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        batteryItem.button?.target = self
        batteryItem.button?.action = #selector(toggleBattery)

        cpuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        cpuItem.button?.target = self
        cpuItem.button?.action = #selector(toggleCPU)

        memoryItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        memoryItem.button?.target = self
        memoryItem.button?.action = #selector(toggleMemory)

        networkItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        networkItem.button?.target = self
        networkItem.button?.action = #selector(toggleNetwork)

        bluetoothItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        bluetoothItem.button?.target = self
        bluetoothItem.button?.action = #selector(toggleBluetooth)
        // The Bluetooth glyph is static (no live number to track), so set it once here rather than
        // rebuilding it every second in refreshLabels.
        bluetoothItem.button?.image = bluetoothMenuBarImage()

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

    @objc private func toggleControlCenter() { toggle(controlCenterPopover, item: controlCenterItem) }
    @objc private func toggleBattery() { toggle(batteryPopover, item: batteryItem) }
    @objc private func toggleNetwork() { toggle(networkPopover, item: networkItem) }
    @objc private func toggleCPU() { toggle(cpuPopover, item: cpuItem) }
    @objc private func toggleMemory() { toggle(memoryPopover, item: memoryItem) }
    @objc private func toggleBluetooth() { toggle(bluetoothPopover, item: bluetoothItem) }

    /// Opens a metric's detail popover from the Control Center overview. Anchors to that metric's
    /// own menu-bar item when it's visible, otherwise to the Control Center button — so tapping a
    /// row works even for an item the user has hidden. Mirrors `toggle`'s single-popover + activate
    /// sequencing so the opened popover is focused and every other one is closed cleanly.
    private func presentDetail(_ metric: StatMetric) {
        let popover: NSPopover
        let ownItem: NSStatusItem?
        switch metric {
        case .battery:   popover = batteryPopover;   ownItem = batteryItem
        case .cpu:       popover = cpuPopover;       ownItem = cpuItem
        case .memory:    popover = memoryPopover;    ownItem = memoryItem
        case .network:   popover = networkPopover;   ownItem = networkItem
        case .bluetooth: popover = bluetoothPopover; ownItem = bluetoothItem
        }
        let anchor = (ownItem?.isVisible == true ? ownItem : controlCenterItem)
        guard let button = anchor?.button else { return }

        for other in allPopovers where other !== popover { other.performClose(nil) }
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.async {
            popover.contentViewController?.view.window?.makeKey()
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
        // Per-item visibility, driven by the Control Center's "show<Item>Item" toggles. Read the
        // same lenient way as the battery glyph flags (absent key ⇒ shown) so a fresh install shows
        // every item. Setting isVisible is a no-op when unchanged; doing it here makes a toggle
        // take effect within ~1 s. The Control Center item itself is never hidden.
        setVisibility(batteryItem, key: "showBatteryItem")
        setVisibility(cpuItem, key: "showCPUItem")
        setVisibility(memoryItem, key: "showMemoryItem")
        setVisibility(networkItem, key: "showNetworkItem")
        setVisibility(bluetoothItem, key: "showBluetoothItem")

        batteryItem?.button?.image = currentBatteryImage()
        cpuItem?.button?.image = symbolPercentMenuBarImage(symbol: "cpu", percent: Int(cpuReader.info.usagePercent.rounded()))
        memoryItem?.button?.image = symbolPercentMenuBarImage(symbol: "memorychip", percent: Int(memoryReader.info.usagePercent.rounded()))
        networkItem?.button?.image = networkMenuBarImage(up: networkReader.info.uploadRate,
                                                         down: networkReader.info.downloadRate)
    }

    /// Show/hide a status item from its UserDefaults toggle (absent key ⇒ shown). We intentionally do
    /// NOT close a hidden item's popover here: the Control Center overview deliberately opens a hidden
    /// metric's detail anchored to the hub button (see presentDetail), and closing it on the next 1 Hz
    /// tick would defeat that. A hide never coincides with the item's own tab popover being open — the
    /// single-popover rule closes it the moment the Control Center opens — so there's nothing to close.
    private func setVisibility(_ item: NSStatusItem?, key: String) {
        item?.isVisible = UserDefaults.standard.object(forKey: key) as? Bool ?? true
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
        // No visible scene — the UI is the two NSStatusItems built in AppDelegate. Settings gives the
        // App a valid (empty, never-shown) scene body.
        Settings { EmptyView() }
    }
}
