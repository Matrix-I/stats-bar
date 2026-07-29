// TemperatureAlerter.swift — fires a hot-battery alert when a connected iPhone/iPad's battery
// crosses 39 °C, nudging you to pull the cable. Nothing here (or anywhere on the host) can actually
// stop an iOS device charging — iOS owns that decision and already throttles/pauses charging when
// hot — so a heads-up to unplug is the most this app can do.
//
// Both alert paths show StatsBar's OWN icon (AppIcon.icns):
//  • Authorized  → a real macOS notification posted by StatsBar via UNUserNotificationCenter.
//    macOS draws the posting app's bundle icon (AppIcon) in the notification's left slot for free.
//    This is the nicer path (Notification Center history, Focus/DND, system sound) but only works
//    once the user has allowed notifications (macOS prompts on first launch of an installed copy).
//  • Otherwise   → a self-drawn borderless HUD in the top-right corner that renders AppIcon.icns
//    loaded straight from the bundle. It needs NO authorization, no bundle-id grant, and no stable
//    code signature, so it can't be defeated by a denied/undetermined permission state or ad-hoc
//    rebuilds — the warning always shows, always with the app's own icon.
//
// (The earlier osascript fallback was dropped: `display notification` is attributed to Script
// Editor and can never carry StatsBar's icon, which is exactly what this file needs to avoid.)

import Foundation
import UserNotifications
import AppKit
import SwiftUI

@MainActor
final class TemperatureAlerter: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    /// Notify once a battery reaches this. iOS itself already pauses charging when it runs hot;
    /// this is just a nudge to pull the cable sooner. Change here to retune the threshold.
    ///
    /// Static and internal so the settings toggle can name the real number instead of keeping a
    /// second, hand-written copy of it — the toggle used to read "(39°C)" as a literal, which would
    /// have gone quietly wrong the moment this line changed.
    static let hotThresholdC: Double = HotDeviceAlertPolicy.defaultThresholdC
    /// The threshold as it appears in UI text, so every mention formats identically.
    static var hotThresholdText: String { String(format: "%.0f°C", hotThresholdC) }

    /// When to alert — the threshold, the re-arm margin, and which UDIDs have already been warned about.
    /// Lives in Sources/Core (HotDeviceAlertPolicy) so the hysteresis is unit-tested; this class keeps
    /// only the delivery. Main-thread only (check() is always called from IOSDeviceReader.publish, which
    /// runs on main).
    private var policy = HotDeviceAlertPolicy()

    /// A bundled .app has a bundle identifier for UNUserNotificationCenter to post as; a bare
    /// binary has none, so it goes straight to the HUD fallback.
    private let hasBundle = Bundle.main.bundleIdentifier != nil

    /// The HUD window + its auto-dismiss timer, retained so rapid re-fires reuse one window instead
    /// of stacking, and so the panel isn't deallocated before the timer runs. Main-thread only.
    private var hudPanel: NSPanel?
    private var hudDismiss: Timer?

    /// Whether the user left the alert on (footer toggle, `alertHotIPhone`). Defaults to true so a
    /// fresh install still warns without any setup — matches the @AppStorage default in the view.
    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "alertHotIPhone") as? Bool ?? true
    }

    /// Whether the HUD fallback plays a sound. On the native path macOS's own notification settings
    /// decide; the HUD had no such control and simply played unconditionally, with nowhere to turn it
    /// off. Defaults true to preserve the existing behaviour for anyone who never opens the toggle.
    private var soundEnabled: Bool {
        UserDefaults.standard.object(forKey: "alertSound") as? Bool ?? true
    }

    override init() {
        super.init()
        // Ask up front so the permission prompt shows on first launch and the nicer native path can
        // be used later. The delegate makes the banner show even if the app is somehow frontmost.
        if hasBundle {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Call on the main thread with the freshly-read devices.
    func check(_ devices: [IOSDeviceInfo]) {
        let due = policy.devicesToAlert(devices, enabled: enabled,
                                        id: \.id, temperature: \.temperatureC)
        for (device, temp) in due { notify(device: device, temp: temp) }
    }

    private func notify(device: IOSDeviceInfo, temp: Double) {
        let name = device.name.isEmpty ? "iPhone" : device.name
        let title = "🔥 iPhone battery hot"
        let body = String(format: "%@ is at %.1f°C — unplug the charger to let it cool.", name, temp)

        // No bundle → no app-owned notification possible; draw our own HUD (still shows AppIcon).
        guard hasBundle else {
            DispatchQueue.main.async { self.deliverViaHUD(title: title, body: body) }
            return
        }

        // Post as StatsBar (its icon) only when notifications are allowed; otherwise the OS
        // silently drops the request, so draw the HUD instead — never osascript, which would show
        // Script Editor's icon. getNotificationSettings' completion runs off the main thread, so
        // hop back to main before any AppKit/window work.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
            default:
                DispatchQueue.main.async { self.deliverViaHUD(title: title, body: body) }
            }
        }
    }

    /// Draws StatsBar's own borderless HUD in the top-right corner, rendering AppIcon.icns loaded
    /// straight from the bundle — so the warning always shows AND always carries the app's own icon,
    /// with no authorization required. Must be called on the main thread.
    private func deliverViaHUD(title: String, body: String) {
        // NSApp.applicationIconImage returns a generic icon for an accessory app, so load the real
        // AppIcon.icns explicitly; fall back to a caution symbol only if the resource is missing.
        let icon: NSImage = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(named: NSImage.cautionName)
            ?? NSImage()

        // Reuse a single panel: tear down any showing one so alerts don't stack.
        hudDismiss?.invalidate()
        hudPanel?.orderOut(nil)

        let host = NSHostingView(rootView: HUDCard(icon: icon, title: title, message: body))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 92)

        let panel = NSPanel(contentRect: host.frame,
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host

        // Pin to the MENU-BAR screen, not NSScreen.main — "main" follows keyboard focus, so on a
        // multi-display desk the alert appeared over whichever screen happened to be active rather
        // than beside the menu bar the app lives in. Origin (0,0) identifies the menu-bar screen in
        // AppKit's global space; the same trick BatteryDetailView uses to size the popover.
        let menuBarScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first
            ?? NSScreen.main
        if let vf = menuBarScreen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - host.frame.width - 12,
                                         y: vf.maxY - host.frame.height - 12))
        }
        panel.orderFrontRegardless()   // show without activating (this is an accessory app)
        if soundEnabled { NSSound(named: NSSound.Name("Basso"))?.play() }

        hudPanel = panel
        // .common mode so the auto-dismiss still fires while a menu/popover is up (event-tracking).
        let t = Timer(timeInterval: 7, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hudPanel?.orderOut(nil)
                self?.hudPanel = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        hudDismiss = t
    }

    // Show the banner even when StatsBar is the active app (without this, a foreground app's
    // notifications are suppressed by default).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Without this, clicking the notification did nothing whatsoever: UNUserNotificationCenter needs
    /// a didReceive implementation to route the response, so the banner just went away and the user
    /// was left where they started. Bringing StatsBar forward is the useful action — the alert is
    /// about a device whose readings live in the battery popover, one click away in the menu bar.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }
}

/// The HUD's contents: StatsBar's icon next to the alert text, on a translucent rounded card.
private struct HUDCard: View {
    let icon: NSImage
    let title: String
    let message: String   // not named `body` — that collides with View.body
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon).resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 340, height: 92, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
