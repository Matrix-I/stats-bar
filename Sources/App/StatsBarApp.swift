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

@MainActor
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
    /// key that shows/hides it, and — for the items whose glyph carries a live number — a builder for
    /// that glyph. `glyph` returns a cheap cache key describing the current inputs plus a thunk that
    /// renders the NSImage; refreshLabels renders only when the key changed (the builders do real CG
    /// drawing + SF Symbol loads) and skips the probe entirely for a hidden item. `glyph` is nil for a
    /// static glyph (Bluetooth), which is set once at creation instead.
    private struct MetricItem {
        let statusItem: NSStatusItem
        let popover: NSPopover
        let visibilityKey: String
        let glyph: (() -> (key: String, render: () -> NSImage)?)?
        let actionTarget: ControlActionTarget
    }

    /// A retained target for an NSControl's target/action that forwards to a Swift closure.
    private final class ControlActionTarget: NSObject {
        private let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func fire() { handler() }
    }

    /// The five toggleable metrics, keyed by StatMetric. Built in applicationDidFinishLaunching, then
    /// driven uniformly (toggle / presentDetail / refreshLabels) instead of one ivar + one @objc
    /// selector each. The Control Center is kept separate — it's never hidden and its glyph is static.
    private var metricItems: [StatMetric: MetricItem] = [:]

    /// Last glyph cache key per metric, so refreshLabels rebuilds a status-item image only when its
    /// inputs actually change instead of every ~1 Hz tick. Main-thread only (refreshLabels runs on
    /// RunLoop.main). An entry exists iff the current button.image was rendered from that key, so a
    /// hidden→shown item whose value never moved keeps its already-correct image without a rebuild.
    private var lastGlyphKey: [StatMetric: String] = [:]

    private var controlCenterItem: NSStatusItem!
    private var controlCenterActionTarget: ControlActionTarget?
    private let controlCenterPopover = NSPopover()

    private var allPopovers: [NSPopover] {
        [controlCenterPopover] + StatMetric.allCases.compactMap { metricItems[$0]?.popover }
    }

    /// Refreshes the live status-item glyphs ~1 Hz (cheap to rebuild; the readers update at that rate
    /// anyway). Also the hook for menu-bar toggle changes to take effect within a second. assumeIsolated
    /// is safe because PollingTimer fires on RunLoop.main, so the closure always runs on the main thread.
    private lazy var labelPoll = PollingTimer { [weak self] in
        MainActor.assumeIsolated { self?.refreshLabels() }
    }
    /// Cached preferences updated on NotificationCenter didChangeNotification, so 1 Hz refreshLabels
    /// ticks read from fast in-memory fields rather than querying UserDefaults on every tick.
    private var metricVisibility: [StatMetric: Bool] = [:]
    private var showMenuBarPercent: Bool = true
    private var showIPhoneMenuBar: Bool = false
    private var showAndroidMenuBar: Bool = false
    private var defaultsObserver: NSObjectProtocol?
    /// Re-entrancy guard for refreshLabels. Assigning NSStatusItem.isVisible makes AppKit persist the
    /// item's autosave position to UserDefaults, which posts UserDefaults.didChangeNotification; the
    /// observer below is registered with `queue: .main` and therefore runs *synchronously* when the post
    /// happens on the main thread, calling straight back into refreshLabels. Without this guard that
    /// recurses until the main thread's stack is exhausted — the crash signature is EXC_BAD_ACCESS
    /// "Thread stack size exceeded due to excessive recursion" repeating through
    /// -[NSSceneStatusItem _setVisible:temporary:] → refreshLabels(). Main-thread only, so a plain Bool
    /// is enough. Dropping a nested call loses nothing: the observer still refreshes the settings cache
    /// before this returns, and the 1 Hz labelPoll applies it on the next tick.
    private var isRefreshingLabels = false

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
        let (ccItem, ccTarget) = makeStatusItem(image: controlCenterMenuBarImage()) { [weak self] in
            guard let self else { return }
            self.toggle(self.controlCenterPopover, item: self.controlCenterItem)
        }
        controlCenterItem = ccItem
        controlCenterActionTarget = ccTarget
        controlCenterItem.button?.setAccessibilityLabel("Control Center")

        // The five toggleable metrics, in menu-bar order (StatMetric's declaration order). Each pairs
        // its reader-typed detail view with the glyph builder refreshLabels rebuilds each tick; the
        // Bluetooth glyph is static, so it's passed as a one-shot image with no live builder.
        addMetric(.battery, key: "showBatteryItem",
                  root: BatteryDetailView(reader: batteryReader, iosReader: iosReader, androidReader: androidReader),
                  glyph: { [weak self] in self?.batteryGlyph() })
        addMetric(.cpu, key: "showCPUItem",
                  root: CPUDetailView(reader: cpuReader),
                  glyph: { [weak self] in self.map { s in
                      let pct = Int(s.cpuReader.info.usagePercent.rounded())
                      return ("\(pct)", { symbolPercentMenuBarImage(symbol: "cpu", percent: pct) })
                  } })
        addMetric(.memory, key: "showMemoryItem",
                  root: MemoryDetailView(reader: memoryReader),
                  glyph: { [weak self] in self.map { s in
                      let pct = Int(s.memoryReader.info.usagePercent.rounded())
                      return ("\(pct)", { symbolPercentMenuBarImage(symbol: "memorychip", percent: pct) })
                  } })
        addMetric(.network, key: "showNetworkItem",
                  root: NetworkDetailView(reader: networkReader),
                  glyph: { [weak self] in self.map { s in
                      let up = s.networkReader.info.uploadRate, down = s.networkReader.info.downloadRate
                      // The network glyph bakes its text colour (it can't be a template), so fold the
                      // appearance into the key — otherwise it wouldn't re-tint on a light/dark switch.
                      let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                      let key = "\(dark ? "d" : "l")|\(menuBarRate(up))|\(menuBarRate(down))"
                      return (key, { networkMenuBarImage(up: up, down: down) })
                  } })
        addMetric(.bluetooth, key: "showBluetoothItem",
                  root: BluetoothDetailView(reader: bluetoothReader),
                  staticImage: bluetoothMenuBarImage())
        // Static glyph, so refreshLabels never revisits it — label it once, here.
        metricItems[.bluetooth]?.statusItem.button?.setAccessibilityLabel(accessibilityLabel(for: .bluetooth))

        updateSettingsCache()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateSettingsCache()
                self?.refreshLabels()
            }
        }

        refreshLabels()
        labelPoll.schedule(every: 1)

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

    /// Creates a variable-length status item wired to `onClick` through a retained closure target.
    private func makeStatusItem(image: NSImage? = nil, onClick: @escaping () -> Void) -> (item: NSStatusItem, target: ControlActionTarget) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let target = ControlActionTarget(onClick)
        item.button?.target = target
        item.button?.action = #selector(ControlActionTarget.fire)
        if let image { item.button?.image = image }
        return (item, target)
    }

    /// Builds one toggleable metric's popover + status item and records it in `metricItems`.
    private func addMetric<Root: View>(_ metric: StatMetric, key: String, root: Root,
                                       staticImage: NSImage? = nil,
                                       glyph: (() -> (key: String, render: () -> NSImage)?)? = nil) {
        let popover = NSPopover()
        configure(popover: popover, root: root)
        let (statusItem, target) = makeStatusItem(image: staticImage) { [weak self] in self?.toggleMetric(metric) }
        metricItems[metric] = MetricItem(statusItem: statusItem, popover: popover,
                                         visibilityKey: key, glyph: glyph, actionTarget: target)
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
        present(m.popover, from: button)
    }

    private func toggle(_ popover: NSPopover, item: NSStatusItem) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        present(popover, from: button)
    }

    /// The one authoritative popover-presentation sequence, shared by `toggle` and `presentDetail`.
    /// The ordering is load-bearing: an accessory app isn't the active app, so a freshly shown
    /// popover opens *unfocused* — its controls wouldn't respond until you clicked into it. So it
    /// closes every other popover first (the single-popover rule keeps switching one-click), then
    /// activates the app FIRST — before show, using the cooperative-activation API on macOS 14+ where
    /// the ignoringOtherApps variant is deprecated and unreliable — then shows, then keys the popover
    /// window on the next run-loop turn, by which point activation has taken effect so makeKey() sticks.
    private func present(_ popover: NSPopover, from button: NSStatusBarButton) {
        for other in allPopovers where other !== popover { other.performClose(nil) }
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.async {
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func closeAll() {
        for p in allPopovers where p.isShown { p.performClose(nil) }
    }

    /// The reader behind a metric's menu-bar item, so refreshLabels can forward item visibility to it.
    /// Bluetooth's glyph is static (no live data on the menu bar), so it uses MetricReader's default
    /// no-op — its polling is already driven purely by its popover.
    private func metricReader(for metric: StatMetric) -> any MetricReader {
        switch metric {
        case .battery:   return batteryReader
        case .cpu:       return cpuReader
        case .memory:    return memoryReader
        case .network:   return networkReader
        case .bluetooth: return bluetoothReader
        }
    }

    private func refreshLabels() {
        // See isRefreshingLabels: setting isVisible below re-enters this method through the
        // UserDefaults observer, and unguarded that recursion overflows the stack.
        guard !isRefreshingLabels else { return }
        isRefreshingLabels = true
        defer { isRefreshingLabels = false }

        // Per-item visibility + live glyphs, driven off the Control Center's "show<Item>Item" toggles.
        // Read the visibility flag the same lenient way as the battery glyph flags (absent key ⇒
        // shown) so a fresh install shows every item; doing it here makes a toggle take effect within
        // ~1 s. The Control Center is never hidden.
        //
        // We intentionally do NOT close a hidden item's popover: the overview deliberately opens a
        // hidden metric's detail anchored to the hub button (see presentDetail), and closing it on the
        // next tick would defeat that. A hide never coincides with the item's own popover being open —
        // the single-popover rule closed it the moment the Control Center opened — so there's nothing
        // to close.
        for metric in StatMetric.allCases {
            guard let m = metricItems[metric] else { continue }
            let visible = metricVisibility[metric] ?? true
            // Assign only on a real change. The setter is NOT free when the value is unchanged:
            // NSSceneStatusItem routes every assignment through -[NSStatusItemScene updateSettings:]
            // and re-persists the item's autosave position, so an unconditional write at 1 Hz posts a
            // UserDefaults change (and wakes the observer) every single tick.
            if m.statusItem.isVisible != visible {
                m.statusItem.isVisible = visible
            }
            // Let the reader stop polling when its item is hidden (and its popover closed): with
            // nothing on screen there's no reason to keep reading. Idempotent — the reader no-ops when
            // the flag is unchanged — so calling it every ~1 Hz tick is cheap.
            metricReader(for: metric).setItemVisible(visible)
            // A hidden item draws nothing — skip its glyph work entirely (no wasted CG render for a
            // button nobody sees). A static-glyph item (glyph == nil, i.e. Bluetooth) had its image
            // and its VoiceOver label set once at creation. Otherwise probe the cheap key and
            // re-render + reassign only when the inputs changed, so an unchanged value doesn't
            // rebuild the image every second.
            guard visible else { continue }
            guard let probe = m.glyph, let (key, render) = probe() else { continue }
            guard lastGlyphKey[metric] != key else { continue }
            m.statusItem.button?.image = render()
            // Every glyph key is a superset of the values its VoiceOver label reads, so refreshing
            // the label here keeps it in step with the image without rebuilding a string each tick.
            m.statusItem.button?.setAccessibilityLabel(accessibilityLabel(for: metric))
            lastGlyphKey[metric] = key
        }
    }

    /// The VoiceOver label for a live metric's status item, describing what its glyph is showing.
    /// Only called when that metric's glyph key changed, so it's rebuilt at the same rate the image is.
    private func accessibilityLabel(for metric: StatMetric) -> String {
        switch metric {
        case .battery:
            let info = batteryReader.info
            return "Battery \(Int(info.chargePercent.rounded()))%" + (info.isPluggedIn ? ", charging" : "")
        case .cpu:
            return "CPU \(Int(cpuReader.info.usagePercent.rounded()))%"
        case .memory:
            return "Memory \(Int(memoryReader.info.usagePercent.rounded()))%"
        case .network:
            let info = networkReader.info
            return "Network up \(menuBarRate(info.uploadRate)), down \(menuBarRate(info.downloadRate))"
        case .bluetooth:
            return "Bluetooth"
        }
    }

    private func updateSettingsCache() {
        let defaults = UserDefaults.standard
        for metric in StatMetric.allCases {
            if let key = metricItems[metric]?.visibilityKey {
                metricVisibility[metric] = defaults.object(forKey: key) as? Bool ?? true
            }
        }
        showMenuBarPercent = defaults.object(forKey: "showMenuBarPercent") as? Bool ?? true
        showIPhoneMenuBar = defaults.bool(forKey: "showIPhoneMenuBar")
        showAndroidMenuBar = defaults.bool(forKey: "showAndroidMenuBar")
    }

    /// The battery status-item glyph, mirroring the old MenuBarLabel logic: a combined Mac+phone glyph
    /// when the iPhone/Android menu-bar toggle is on and a device is readable, otherwise the plain Mac
    /// battery. iPhone wins over Android when both are present, to keep the item from growing a third
    /// glyph. Returns a cache key over the visible inputs plus a render thunk, so refreshLabels
    /// rebuilds the image only when one of those inputs changes rather than every tick.
    private func batteryGlyph() -> (key: String, render: () -> NSImage) {
        let showPercent = showMenuBarPercent
        let showIPhone = showIPhoneMenuBar
        let showAndroid = showAndroidMenuBar
        let info = batteryReader.info
        let macPct = Int(info.chargePercent.rounded())
        let pct = showPercent ? 1 : 0

        if showIPhone, let ios = iosReader.devices.first, let cp = ios.chargePercent {
            let phonePct = Int(cp.rounded())
            let key = "ios|\(pct)|\(macPct)|\(info.isPluggedIn ? 1 : 0)|\(phonePct)|\(ios.isPluggedIn ? 1 : 0)"
            return (key, {
                dualMenuBarImage(macPct: macPct, macCharging: info.isPluggedIn,
                                 phonePct: phonePct, phoneCharging: ios.isPluggedIn,
                                 phoneSymbol: "iphone", showPercent: showPercent)
            })
        }
        if showAndroid, let android = androidReader.devices.first, let level = android.levelPercent {
            let key = "android|\(pct)|\(macPct)|\(info.isPluggedIn ? 1 : 0)|\(level)|\(android.isPluggedIn ? 1 : 0)"
            return (key, {
                dualMenuBarImage(macPct: macPct, macCharging: info.isPluggedIn,
                                 phonePct: level, phoneCharging: android.isPluggedIn,
                                 phoneSymbol: "candybarphone", showPercent: showPercent)
            })
        }
        let key = "mac|\(pct)|\(macPct)|\(info.isPluggedIn ? 1 : 0)"
        return (key, {
            batteryMenuBarImage(level: info.chargePercent / 100,
                                charging: info.isPluggedIn,
                                percent: showPercent ? macPct : nil)
        })
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
