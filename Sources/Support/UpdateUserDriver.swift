// UpdateUserDriver.swift — a compact, single-window replacement for Sparkle's standard update UI.
//
// Sparkle's SPUStandardUpdaterController ships a multi-window flow (a checking window, a big
// release-notes web view, a download-progress window, a "ready to install & relaunch" prompt).
// StatsBar wants the one-glance dialog a menu-bar utility usually shows: the app icon, the current
// vs latest version, and Close / Changelog / Install — the same information the screenshot the user
// referenced condenses into a single card.
//
// We keep ALL of Sparkle's machinery (feed fetch, EdDSA verification, in-place install & relaunch —
// see Updater / build_app.sh) and only replace the *presentation* by implementing SPUUserDriver
// ourselves. Every driver callback drives one reusable NSWindow through UpdateViewModel; Sparkle
// hands us completion blocks (reply / acknowledgement / cancellation) that MUST each be invoked
// exactly once or the updater stalls, so the driver funnels every "user closed / cancelled" path
// through `dismissByUser()`, which calls whichever block the current phase installed and then clears
// it. The protocol is main-actor (NS_SWIFT_UI_ACTOR), so the whole driver is @MainActor.

import SwiftUI
import AppKit
import Sparkle

// MARK: - View model

/// What the update window is currently showing. The driver sets `phase` last on every transition
/// (after wiring the button closures below), so a phase change is what re-renders the view.
enum UpdatePhase {
    case checking
    case available(current: String, latest: String)
    case upToDate(current: String)
    case downloading(fraction: Double?)   // nil ⇒ indeterminate (length not yet known)
    case installing
    case error(String)
}

/// Bridges the driver to the SwiftUI window. `phase` is the only @Published field; the button
/// handlers are plain closures the driver rewires on each phase so the buttons forward straight to
/// Sparkle's completion blocks. `onShowNotes` is nil when there's no release-notes URL, which hides
/// the Changelog button.
@MainActor
final class UpdateViewModel: ObservableObject {
    @Published var phase: UpdatePhase = .checking
    var onInstall: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onShowNotes: (() -> Void)?
}

// MARK: - Window

/// Owns the single reusable update window and hosts `UpdateWindowView`. The window auto-sizes to the
/// SwiftUI content (preferredContentSize) so each phase gets a snug card. `.closable` only (no
/// resize/minimise) matches a fixed dialog; the red button routes through `windowShouldClose` to the
/// view model's dismiss handler so closing the window means the same as clicking Close.
@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {
    let model = UpdateViewModel()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: UpdateWindowView(model: model))
            host.sizingOptions = [.preferredContentSize]
            let win = NSWindow(contentViewController: host)
            win.styleMask = [.titled, .closable]
            win.title = "StatsBar"
            win.isReleasedWhenClosed = false   // reuse across checks; closing only orders it out
            win.level = .floating               // an accessory app has no Dock/window list to fall behind
            win.delegate = self
            window = win
        }
        // An accessory (LSUIElement) app isn't the active app, so activate first — otherwise the
        // window opens unfocused and its buttons won't respond until clicked into (same reason the
        // menu-bar popovers activate before showing).
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() { window?.orderOut(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.onDismiss()   // treat the red button exactly like the Close button
        return true         // isReleasedWhenClosed == false ⇒ this just orders the window out
    }
}

// MARK: - View

/// The update card. Deliberately compact: an icon + a headline + (for an available update) the
/// version comparison, over a single row of buttons. Renders in whichever theme the window uses.
private struct UpdateWindowView: View {
    @ObservedObject var model: UpdateViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            content
            buttons
        }
        .padding(24)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checking:
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").font(.system(size: 14, weight: .medium))
            }

        case let .available(current, latest):
            HStack(alignment: .top, spacing: 16) {
                appIcon
                VStack(alignment: .leading, spacing: 12) {
                    Text("New version available").font(.system(size: 17, weight: .semibold))
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        versionRow("Current version:", current, color: .secondary)
                        versionRow("Latest version:", latest, color: .primary)
                    }
                }
            }

        case let .upToDate(current):
            HStack(alignment: .top, spacing: 16) {
                appIcon
                VStack(alignment: .leading, spacing: 6) {
                    Text("You're up to date").font(.system(size: 17, weight: .semibold))
                    Text("StatsBar \(current) is the latest version.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }

        case let .downloading(fraction):
            VStack(alignment: .leading, spacing: 10) {
                Text("Downloading update…").font(.system(size: 14, weight: .medium))
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }

        case .installing:
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                Text("Installing update…").font(.system(size: 14, weight: .medium))
            }

        case let .error(message):
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Update failed").font(.system(size: 17, weight: .semibold))
                    Text(message).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.phase {
        case .available:
            HStack {
                Button("Close") { model.onDismiss() }
                Spacer()
                if let showNotes = model.onShowNotes {
                    Button("Changelog") { showNotes() }
                }
                Button("Install") { model.onInstall() }
                    .keyboardShortcut(.defaultAction)
            }

        case .checking, .downloading:
            HStack {
                Spacer()
                Button("Cancel") { model.onDismiss() }
            }

        case .upToDate, .error:
            HStack {
                Spacer()
                Button("OK") { model.onDismiss() }.keyboardShortcut(.defaultAction)
            }

        case .installing:
            EmptyView()   // no user action — the app is about to relaunch
        }
    }

    private func versionRow(_ label: String, _ value: String, color: Color) -> some View {
        GridRow {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable().frame(width: 60, height: 60)
    }
}

// MARK: - Driver

/// Our SPUUserDriver: translates Sparkle's callbacks into UpdateViewModel phases and funnels every
/// completion block through a single pending-handler slot. Sparkle guarantees these are all called on
/// the main thread; the class is @MainActor to match the protocol's main-actor annotation.
@MainActor
final class SimpleUpdateUserDriver: NSObject, SPUUserDriver {
    private let window = UpdateWindowController()

    // Exactly one of these is armed at a time — whatever the current phase needs to hand back to
    // Sparkle. `dismissByUser()` fires whichever is set (and clears it) so Close/Cancel/red-button
    // all resolve the outstanding block once.
    private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    private var acknowledgement: (() -> Void)?
    private var cancellation: (() -> Void)?

    // Only pop the "up to date" / error window for a check the user started — background scheduled
    // checks must stay silent when there's nothing new.
    private var userInitiated = false

    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    private var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? "—"
    }

    /// Invoke the armed completion block once, then clear every slot and hide the window. Used for
    /// the Close / Cancel / red-button paths. The priority order (reply → ack → cancellation) is safe
    /// because at most one slot is ever armed: every "new interaction state" entry point below calls
    /// `clearHandlers()` first, dropping the previous state's now-obsolete obligation (Sparkle drives
    /// these states sequentially, so a superseded block is never one Sparkle still waits on).
    private func dismissByUser() {
        if let reply = updateReply { reply(.dismiss) }
        else if let ack = acknowledgement { ack() }
        else if let cancel = cancellation { cancel() }
        clearHandlers()
        window.hide()
    }

    /// Drop every armed completion block WITHOUT calling it. Called when moving to a new interaction
    /// state (the prior block is obsolete) and on teardown (dismissUpdateInstallation).
    private func clearHandlers() {
        updateReply = nil
        acknowledgement = nil
        cancellation = nil
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // No first-launch dialog — the Control Center already exposes an explicit "Automatically
        // check for updates" toggle. Grant checks, never send a system profile.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
        clearHandlers()
        self.cancellation = cancellation
        window.model.onDismiss = { [weak self] in self?.dismissByUser() }
        window.model.onShowNotes = nil
        window.model.phase = .checking
        window.show()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        clearHandlers()
        updateReply = reply

        let notesURL = appcastItem.releaseNotesURL ?? appcastItem.fullReleaseNotesURL ?? appcastItem.infoURL
        window.model.onInstall = { [weak self] in
            guard let self, let reply = self.updateReply else { return }
            self.updateReply = nil
            self.window.model.phase = .downloading(fraction: nil)   // bridge the gap until Sparkle reports progress
            reply(.install)
        }
        window.model.onDismiss = { [weak self] in self?.dismissByUser() }
        window.model.onShowNotes = notesURL.map { url in { NSWorkspace.shared.open(url) } }
        window.model.phase = .available(current: currentVersion, latest: "v" + appcastItem.displayVersionString)
        window.show()
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // We link out to the Changelog in a browser instead of rendering notes in-window — nothing to do.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // See showUpdateReleaseNotes — release notes aren't shown in-window, so a failure is harmless.
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard userInitiated else { acknowledgement(); return }   // stay silent for background checks
        clearHandlers()
        self.acknowledgement = acknowledgement
        window.model.onDismiss = { [weak self] in self?.dismissByUser() }
        window.model.onShowNotes = nil
        window.model.phase = .upToDate(current: currentVersion)
        window.show()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        clearHandlers()
        self.acknowledgement = acknowledgement
        window.model.onDismiss = { [weak self] in self?.dismissByUser() }
        window.model.onShowNotes = nil
        window.model.phase = .error(error.localizedDescription)
        window.show()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        clearHandlers()
        self.cancellation = cancellation
        expectedLength = 0
        receivedLength = 0
        window.model.onDismiss = { [weak self] in self?.dismissByUser() }
        window.model.phase = .downloading(fraction: nil)
        window.show()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        guard expectedLength > 0 else { return }
        window.model.phase = .downloading(fraction: min(1, Double(receivedLength) / Double(expectedLength)))
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil                       // past the point a Cancel could unwind cleanly
        window.model.onDismiss = {}
        window.model.phase = .installing
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        window.model.phase = .installing
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // The user already chose Install; don't ask a second time — install and relaunch straight away.
        window.model.phase = .installing
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        window.model.phase = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        window.show()
    }

    func dismissUpdateInstallation() {
        // Sparkle is tearing everything down: drop the blocks WITHOUT calling them (they're being
        // invalidated) and hide the window.
        clearHandlers()
        userInitiated = false
        window.hide()
    }
}
