// Updater.swift — thin wrapper around Sparkle's standard updater. AppDelegate owns one for the app's
// lifetime; the Control Center's General section drives it ("Check for updates…" + an automatic-check
// toggle). The feed URL and public EdDSA key live in Info.plist (SUFeedURL / SUPublicEDKey, set by
// build_app.sh), so no delegate wiring is needed here.
//
// Sparkle downloads updates through its own machinery (not a browser), so the downloaded app never
// gets a com.apple.quarantine flag — Gatekeeper doesn't block the in-place update even though StatsBar
// isn't notarized. Integrity is guaranteed by the EdDSA signature in the appcast instead.

import Foundation
import Sparkle

final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true launches the background scheduler immediately, honouring the user's
        // automatic-check preference. Passing nil delegates uses the standard user driver (Sparkle's
        // own "update available" / "you're up to date" windows), which works for an accessory app.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// A user-initiated check — shows Sparkle's UI whether or not an update is found.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Backs the "Automatically check for updates" toggle. Sparkle persists this itself.
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
