// FanController.swift — the app's side of fan control: the connection to the root helper, and the mode
// the popover's Auto · Max · Manual control shows.
//
// The helper, not this class, is what keeps the fans safe. It hands them back to the SMC on its own
// when this connection closes, when pings stop, and when the Mac sleeps (see Helper/main.swift). This
// class only has to keep its picture of the mode honest: every failure — a command refused, the helper
// gone, a ping answered with "back under automatic control" — snaps the control to Auto, because Auto
// is what the fans are actually doing by then.
//
// Socket I/O happens on a serial background queue (HelperConnection below). Commands are a few bytes
// each way to a local process, but a blocked read on the main thread would freeze the menu bar, and a
// helper that has just been booted out by an update is exactly the case where a read would block.

import AppKit
import Foundation

@MainActor
final class FanController: ObservableObject {
    enum Mode: Equatable { case auto, max, manual }

    enum HelperState: Equatable {
        case unknown
        case notInstalled
        case needsUpdate
        case unavailable(String)
        case ready
    }

    @Published private(set) var mode: Mode = .auto
    @Published private(set) var helper: HelperState = .unknown
    /// One line under the mode control; cleared by the next successful command.
    @Published private(set) var message: String?
    /// True while an install/uninstall password dialog is up, so the button can't be pressed twice.
    @Published private(set) var isInstalling = false
    /// The speed each fan's slider sits at in Manual. Kept across Auto/Max so returning to Manual puts
    /// the sliders back where the user left them — for this session only, as the spec requires.
    @Published private(set) var manualTargets: [Int: Double] = [:]

    private let connection = HelperConnection()
    private var pingTimer: Timer?
    private var sleepObserver: NSObjectProtocol?

    init() {
        // The helper restores Auto before the Mac sleeps; this just makes the control agree on wake
        // instead of waiting for the next ping to discover it.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fell(back: nil) }
        }
    }

    /// Re-derives the helper state. Called when the popover opens; cheap enough to do every time.
    func refresh() {
        guard FanHelperInstaller.bundledHelper != nil else {
            helper = .unavailable("This build does not include the fan helper.")
            return
        }
        guard FanHelperInstaller.isInstalled else { helper = .notInstalled; return }
        guard FanHelperInstaller.installedMatchesBundle else { helper = .needsUpdate; return }
        send(.version) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.version(FanProtocol.version)): self.helper = .ready
            case .success(.version): self.helper = .needsUpdate
            case .success: self.helper = .unavailable("The fan helper gave an unexpected reply.")
            case let .failure(reason): self.helper = .unavailable(reason.description)
            }
        }
    }

    func setMode(_ newMode: Mode, fans: [FanInfo]) {
        guard newMode != mode else { return }
        switch newMode {
        case .auto:
            fell(back: nil)
            send(.auto) { _ in }
        case .max:
            apply([.max], as: .max)
        case .manual:
            // Each fan starts at its last chosen speed, or where it is spinning right now — so the
            // switch to Manual is silent rather than a lurch to some default.
            let commands = fans.map { fan -> FanCommand in
                let rpm = manualTargets[fan.index] ?? fan.actual
                manualTargets[fan.index] = rpm
                return .set(fan: fan.index, rpm: rpm)
            }
            apply(commands, as: .manual)
        }
    }

    /// The slider moved. Sent only on release (the view decides when), so a drag is one command.
    func setTarget(fan: Int, rpm: Double) {
        manualTargets[fan] = rpm
        guard mode == .manual else { return }
        apply([.set(fan: fan, rpm: rpm)], as: .manual)
    }

    func installHelper() {
        runInstaller(FanHelperInstaller.install)
    }

    func uninstallHelper() {
        fell(back: nil)
        runInstaller(FanHelperInstaller.uninstall)
    }

    /// Called from applicationWillTerminate. Not load-bearing — quitting closes the socket and the
    /// helper restores Auto on its own — but it makes a normal quit hand the fans back before the
    /// process is gone rather than as a consequence of it.
    func restoreAutoBeforeExit() {
        guard mode != .auto else { return }
        connection.sendSync(.auto)
    }

    // MARK: -

    private func runInstaller(_ action: @escaping (@escaping (String?) -> Void) -> Void) {
        isInstalling = true
        connection.disconnect()
        action { [weak self] error in
            guard let self else { return }
            self.isInstalling = false
            self.message = error
            self.refresh()
        }
    }

    private func apply(_ commands: [FanCommand], as newMode: Mode) {
        sendAll(commands) { [weak self] failure in
            guard let self else { return }
            if let failure {
                self.fell(back: failure)
                // A failed command already made the helper restore Auto; this just tells it so if the
                // failure was on our side of the socket.
                self.send(.auto) { _ in }
            } else {
                self.mode = newMode
                self.message = nil
                self.startPinging()
            }
        }
    }

    /// The control goes to Auto, with an optional reason shown under it.
    private func fell(back reason: String?) {
        mode = .auto
        message = reason
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func startPinging() {
        guard pingTimer == nil else { return }
        pingTimer = Timer.scheduledTimer(withTimeInterval: FanControlTiming.pingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.send(.ping) { result in
                    guard let self, self.mode != .auto else { return }
                    switch result {
                    case .success(.ok): break
                    case .success(.error(FanProtocol.notOverridden)):
                        self.fell(back: "The fans went back to automatic control.")
                    case let .success(other): self.fell(back: "Unexpected reply: \(other.line)")
                    case let .failure(reason): self.fell(back: reason.description)
                    }
                }
            }
        }
    }

    private func send(_ command: FanCommand, completion: @escaping (Result<FanReply, HelperError>) -> Void) {
        connection.send(command) { result in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// Sends in order and stops at the first failure, which is reported as a message.
    private func sendAll(_ commands: [FanCommand], completion: @escaping (String?) -> Void) {
        guard let first = commands.first else { return completion(nil) }
        send(first) { [weak self] result in
            switch result {
            case .success(.ok): self?.sendAll(Array(commands.dropFirst()), completion: completion)
            case let .success(.error(reason)): completion(reason)
            case let .success(other): completion("Unexpected reply: \(other.line)")
            case let .failure(reason): completion(reason.description)
            }
        }
    }
}

struct HelperError: Error, CustomStringConvertible, Equatable {
    let description: String
}

/// The socket, touched only on its own serial queue. Kept open between commands: the helper treats
/// the connection closing as "the app is gone" and restores Auto, so a connection per command would
/// hand the fans back after every one.
private final class HelperConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FanController.connection")
    private var fd: Int32 = -1

    func send(_ command: FanCommand, completion: @escaping (Result<FanReply, HelperError>) -> Void) {
        queue.async { completion(self.exchange(command)) }
    }

    func sendSync(_ command: FanCommand) {
        queue.sync { _ = self.exchange(command) }
    }

    func disconnect() {
        queue.async { self.closeSocket() }
    }

    private func exchange(_ command: FanCommand) -> Result<FanReply, HelperError> {
        if fd < 0, let error = connect() { return .failure(error) }
        let bytes = Array((command.line + "\n").utf8)
        let written = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else {
            closeSocket()
            return .failure(HelperError(description: "Lost the connection to the fan helper."))
        }
        // Byte at a time is fine for replies a dozen bytes long, and it means nothing past the newline
        // is ever read into a buffer this side would then have to carry to the next exchange.
        var line = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            guard n == 1 else {
                closeSocket()
                return .failure(HelperError(description: "The fan helper did not answer."))
            }
            if byte == UInt8(ascii: "\n") { break }
            line.append(byte)
            guard line.count < 4096 else {
                closeSocket()
                return .failure(HelperError(description: "The fan helper sent an overlong reply."))
            }
        }
        guard let reply = FanReply(line: String(decoding: line, as: UTF8.self)) else {
            return .failure(HelperError(description: "The fan helper sent an unreadable reply."))
        }
        return .success(reply)
    }

    private func connect() -> HelperError? {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return HelperError(description: "Could not create a socket.") }
        // Two seconds each way: a SMC write with its retries takes at most ~0.5 s per fan, so anything
        // slower is a helper that is not going to answer.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, byte) in FanProtocol.socketPath.utf8.enumerated() where i < dst.count - 1 { dst[i] = byte }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            Darwin.close(s)
            return HelperError(description: "The fan helper is not running.")
        }
        fd = s
        return nil
    }

    private func closeSocket() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }
}
