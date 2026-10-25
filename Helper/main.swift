// main.swift — local.statsbar.fanhelper, the root LaunchDaemon that lets StatsBar override the fans.
//
// It exists because SMC writes need root and the app is signed with a self-signed identity, which
// rules out SMAppService and SMJobBless. FanHelperInstaller puts this binary in
// /Library/PrivilegedHelperTools with an administrator prompt, once, and launchd keeps it running.
//
// The design rule is that every path ends in Auto. A process that runs as root and holds the fans at a
// fixed speed is only safe if it lets go the moment its client can no longer be trusted to be paying
// attention, so the fans are handed back to the SMC when:
//
//   - the app's connection closes — quit, crash, `kill -9`: the kernel closes the socket for us;
//   - nothing has arrived for FanControlTiming.watchdog seconds while a fan is overridden — the app
//     is hung with its socket still open;
//   - the Mac is about to sleep — nobody is watching, and the app's control would be stale on wake;
//   - this process gets SIGTERM — uninstall, `launchctl bootout`, shutdown;
//   - this process starts — a previous instance may have died with fans in manual mode, and launchd's
//     KeepAlive restart is the first chance to undo that.
//
// Only one user may connect: the uid passed as `--uid`, which the installer sets to the user who
// installed it. The socket file is chowned to that user and 0600, and every connection's peer is
// checked with getpeereid as well, so another account on the same Mac cannot drive the fans.

import Foundation
import IOKit
import IOKit.pwr_mgt

guard let uidIndex = CommandLine.arguments.firstIndex(of: "--uid"),
      uidIndex + 1 < CommandLine.arguments.count,
      let allowedUID = uid_t(CommandLine.arguments[uidIndex + 1]) else {
    log("usage: \(FanProtocol.helperLabel) --uid <uid>")
    exit(64)
}
guard getuid() == 0 else {
    log("must run as root")
    exit(77)
}

let queue = DispatchQueue(label: FanProtocol.helperLabel)
let smc = SMCWriter()
guard smc.isAvailable else {
    log("AppleSMC is unavailable")
    exit(69)
}
let fans = Fans(smc: smc)

// MARK: - Client connection

final class Client {
    let fd: Int32
    private var buffer = Data()
    private var source: DispatchSourceRead?
    private(set) var lastSeen = Date()
    var onClose: (() -> Void)?

    init(fd: Int32) { self.fd = fd }

    func start() {
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [unowned self] in self.readAvailable() }
        s.setCancelHandler { [fd] in Darwin.close(fd) }
        source = s
        s.resume()
    }

    func close() {
        source?.cancel()
        source = nil
        onClose?()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { return close() }
        buffer.append(contentsOf: chunk[0..<n])
        // A client that never sends a newline is not speaking the protocol; capping the buffer stops
        // it from growing a root process's memory without bound.
        guard buffer.count <= 4096 else { return close() }
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            lastSeen = Date()
            reply(handle(line))
        }
    }

    private func reply(_ r: FanReply) {
        let bytes = Array((r.line + "\n").utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }
}

func handle(_ line: String) -> FanReply {
    guard let command = FanCommand(line: line) else { return .error("unknown command") }
    do {
        switch command {
        case .version:
            return .version(FanProtocol.version)
        case .ping:
            return fans.overridden.isEmpty ? .error(FanProtocol.notOverridden) : .ok
        case let .set(fan, rpm):
            try fans.set(fan: fan, rpm: rpm)
        case .max:
            try fans.driveAllToMax()
        case .auto:
            fans.restoreAuto()
        }
        return .ok
    } catch {
        // A half-applied override is worse than none: hand everything back before reporting.
        fans.restoreAuto()
        log("\(line): \(error)")
        return .error(String(describing: error))
    }
}

var client: Client?

// MARK: - Listening socket

func listenSocket() -> Int32 {
    let path = FanProtocol.socketPath
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { log("socket: \(errno)"); exit(71) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.utf8.count < capacity else { log("socket path too long"); exit(71) }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        for (i, byte) in path.utf8.enumerated() { dst[i] = byte }
    }
    // Created 0600 and root-owned before anyone can connect, then handed to the one allowed user —
    // there is no window in which the socket is open to everyone.
    let oldMask = umask(0o177)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    umask(oldMask)
    guard bound == 0 else { log("bind: \(errno)"); exit(71) }
    guard chown(path, allowedUID, gid_t.max) == 0, chmod(path, 0o600) == 0 else {
        log("chown/chmod: \(errno)"); exit(71)
    }
    guard listen(fd, 4) == 0 else { log("listen: \(errno)"); exit(71) }
    return fd
}

let listener = listenSocket()
let acceptSource = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
acceptSource.setEventHandler {
    let fd = accept(listener, nil, nil)
    guard fd >= 0 else { return }
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == allowedUID else {
        log("refused a connection from uid \(peerUID)")
        close(fd)
        return
    }
    // One client at a time. A second StatsBar (or anything else running as this user) is refused
    // rather than allowed to fight the first over the same fans.
    guard client == nil else {
        close(fd)
        return
    }
    let c = Client(fd: fd)
    c.onClose = {
        client = nil
        if !fans.overridden.isEmpty { log("client went away — restoring automatic control") }
        fans.restoreAuto()
    }
    client = c
    c.start()
}
acceptSource.resume()

// MARK: - Watchdog

let watchdog = DispatchSource.makeTimerSource(queue: queue)
watchdog.schedule(deadline: .now() + 1, repeating: 1)
watchdog.setEventHandler {
    guard !fans.overridden.isEmpty, let c = client else { return }
    if Date().timeIntervalSince(c.lastSeen) > FanControlTiming.watchdog {
        log("no ping for \(Int(FanControlTiming.watchdog)) s — restoring automatic control")
        fans.restoreAuto()
    }
}
watchdog.resume()

// MARK: - Sleep

// IOMessage.h builds these with iokit_common_msg(), a function-like macro Swift does not import:
// sys_iokit (err_system(0x38) = 0xE0000000) | sub_iokit_common (0) | the message number.
let messageCanSystemSleep: UInt32 = 0xE000_0270
let messageSystemWillSleep: UInt32 = 0xE000_0280

var rootPort: io_connect_t = 0
var notifier: io_object_t = 0
var notifyPort: IONotificationPortRef?
rootPort = IORegisterForSystemPower(nil, &notifyPort, { _, _, messageType, argument in
    // Both messages need an answer or sleep is delayed by the 30 s timeout. Restoring before
    // acknowledging WillSleep means the fans are back with the SMC before the Mac goes down.
    switch messageType {
    case messageCanSystemSleep:
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case messageSystemWillSleep:
        if !fans.overridden.isEmpty { log("system sleep — restoring automatic control") }
        fans.restoreAuto()
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    default:
        break
    }
}, &notifier)
if rootPort != 0, let port = notifyPort {
    IONotificationPortSetDispatchQueue(port, queue)
} else {
    log("IORegisterForSystemPower failed — fans will not be restored on sleep")
}

// MARK: - Termination

signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
termSource.setEventHandler {
    fans.restoreAuto()
    unlink(FanProtocol.socketPath)
    exit(0)
}
termSource.resume()

queue.async {
    fans.restoreAuto()
    log("started, protocol \(FanProtocol.version), \(fans.count) fan(s), serving uid \(allowedUID)")
}
dispatchMain()
