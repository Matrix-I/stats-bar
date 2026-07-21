// LoginItem.swift — a thin wrapper over ServiceManagement's SMAppService for the "Launch at login"
// toggle in the Control Center. SMAppService.mainApp registers the app bundle itself as a login
// item (macOS 13+, which this app already targets), so there's no separate helper bundle to ship.
//
// register()/unregister() can throw (e.g. the app isn't in a launchable location, or the user
// disabled it in System Settings ▸ General ▸ Login Items) — we swallow and log those so the toggle
// never crashes the app. `status` is the source of truth we read back, so the toggle always shows
// the real state rather than a value we cached.

import Foundation
import ServiceManagement

enum LoginItem {
    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the app as a login item. No-ops when already in the requested state,
    /// and logs (rather than throws) on failure so a denied request can't take the app down.
    static func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("StatsBar: launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }
}
