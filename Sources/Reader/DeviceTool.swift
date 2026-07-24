// DeviceTool.swift — shared command-line plumbing for the USB device readers.
//
// The iOS reader (libimobiledevice) and the Android reader (adb) both need the same two things:
// locate a Homebrew/system CLI tool, and run it with a hard timeout that drains both pipes
// concurrently. That logic was duplicated verbatim in both readers; it lives here once now.

import Foundation

enum DeviceTool {
    /// Where CLI tools installed via Homebrew (Apple Silicon + Intel) or the system live.
    static let searchDirs = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"]

    /// Kill a tool that overruns this — unplugging a device mid-read can otherwise leave a
    /// libimobiledevice/adb process blocked indefinitely and wedge the calling reader.
    private static let toolTimeout: TimeInterval = 4

    /// First existing/executable path for `name` across `searchDirs`, or nil if not installed.
    static func path(_ name: String) -> String? {
        for dir in searchDirs {
            let p = dir + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Modern async wrapper for executing a command with timeout and concurrent pipe draining.
    static func runAsync(_ path: String, _ args: [String], timeout: TimeInterval = toolTimeout) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            run(path, args, timeout: timeout)
        }.value
    }

    /// Runs a command, returns stdout if the exit code is 0, nil otherwise. Reads both pipes
    /// concurrently — reading them sequentially (stdout then stderr) can deadlock if the child
    /// process fills the stderr buffer while we're still waiting for EOF on stdout.
    ///
    /// Bails out if the tool overruns `timeout`: unplugging the device mid-read can leave
    /// idevicediagnostics / ideviceinfo / adb blocked indefinitely, which would otherwise hang the
    /// reader thread (waitUntilExit never returns), wedge its isBusy flag at true, and freeze the
    /// whole section until relaunch.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = toolTimeout) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return nil
        }

        final class DataContainer: @unchecked Sendable {
            var data = Data()
        }
        let outContainer = DataContainer()

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outContainer.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()                          // SIGTERM
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            if group.wait(timeout: .now() + 1) == .timedOut {
                // The tool ignored SIGTERM (e.g. blocked in a usbmux syscall on a locked device).
                // Escalate to SIGKILL so the child dies, its pipe write-ends close, and the two
                // reader work items above hit EOF and unwind — otherwise they leak, blocked on
                // readDataToEndOfFile, once per timed-out call. Deliberately no waitUntilExit()
                // here: it could block unbounded if the child is wedged in an uninterruptible
                // kernel wait, re-introducing the very hang toolTimeout exists to prevent.
                // Foundation reaps the child asynchronously once it actually dies.
                kill(process.processIdentifier, SIGKILL)
                _ = group.wait(timeout: .now() + 1)
            }
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? outContainer.data : nil
    }
}
