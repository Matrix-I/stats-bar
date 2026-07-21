// Updater.swift — thin wrapper around Sparkle's updater. AppDelegate owns one for the app's lifetime;
// the Control Center's General section drives it ("Check for updates…" + an automatic-check toggle).
// The feed URL and public EdDSA key live in Info.plist (SUFeedURL / SUPublicEDKey, set by
// build_app.sh), so no updater-delegate wiring is needed here.
//
// Unlike a plain SPUStandardUpdaterController, we drive SPUUpdater directly with our own
// SPUUserDriver (SimpleUpdateUserDriver) so the whole update interaction is one compact window
// instead of Sparkle's default multi-window flow. Everything else — background scheduling, download,
// EdDSA verification, in-place install & relaunch — is still stock Sparkle.
//
// Sparkle downloads updates through its own machinery (not a browser), so the downloaded app never
// gets a com.apple.quarantine flag — Gatekeeper doesn't block the in-place update even though StatsBar
// isn't notarized. Integrity is guaranteed by the EdDSA signature in the appcast instead.

import Foundation
import Sparkle

@MainActor
final class Updater: ObservableObject {
    private let driver = SimpleUpdateUserDriver()
    private let updater: SPUUpdater

    init() {
        // Drive SPUUpdater ourselves so `driver` renders the UI. startUpdater launches the background
        // scheduler (honouring the user's automatic-check preference); if it can't start (a bundle
        // misconfiguration), log and carry on — the app still runs, just without updates.
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do {
            try updater.start()
        } catch {
            NSLog("StatsBar: Sparkle updater failed to start — \(error.localizedDescription)")
        }
    }

    /// A user-initiated check — shows the update window whether or not an update is found.
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// Backs the "Automatically check for updates" toggle. Sparkle persists this itself.
    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
}
