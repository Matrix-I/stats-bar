// FanHelperInstaller.swift — puts the root fan helper in place, and takes it away again, with one
// administrator prompt each.
//
// Why osascript rather than SMAppService or SMJobBless: both require the app to be signed by a
// Developer ID, and StatsBar is signed with the self-signed "StatsBar Local" identity (see CLAUDE.md
// on why that identity must not change). `do shell script … with administrator privileges` asks for
// the password in the system's own dialog and needs nothing from the signature. The commands it runs
// are built in Core (FanHelperInstallScript), where the quoting is tested.

import Foundation
import Security

enum FanHelperInstaller {
    /// The helper build_app.sh embeds next to the app's other resources; nil in a build without it.
    static var bundledHelper: URL? {
        Bundle.main.url(forResource: FanProtocol.helperLabel, withExtension: nil)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: FanHelperInstallScript.installedBinary)
    }

    /// True when the installed helper is the same code as the one in this bundle. Compared by code
    /// directory hash rather than by a version number, because the helper's behaviour can change
    /// without its protocol changing — and after a Sparkle update the old helper is still the one
    /// running as root.
    ///
    /// Not by bytes either: the signature embeds its signing time, so two signings of identical code
    /// differ, and a byte comparison asked for an update after every rebuild. The cdhash covers the
    /// code and nothing else. The installed copy is 0755, so reading it needs no privilege.
    static var installedMatchesBundle: Bool {
        guard let bundled = bundledHelper,
              let a = cdhash(bundled),
              let b = cdhash(URL(fileURLWithPath: FanHelperInstallScript.installedBinary)) else { return false }
        return a == b
    }

    private static func cdhash(_ url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoUnique as String] as? Data
    }

    /// Installs (or replaces) the helper. Calls back on the main queue with nil on success, or a
    /// message to show — including when the user cancels the password dialog.
    static func install(completion: @escaping (String?) -> Void) {
        guard let bundled = bundledHelper else {
            return completion("This build does not include the fan helper.")
        }
        let plistFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(FanProtocol.helperLabel).plist")
        do {
            try FanHelperInstallScript.plist(uid: getuid()).write(to: plistFile, atomically: true, encoding: .utf8)
        } catch {
            return completion("Could not write the launchd job: \(error.localizedDescription)")
        }
        let script = FanHelperInstallScript.install(bundledHelper: bundled.path, plistFile: plistFile.path)
        runPrivileged(script) { error in
            try? FileManager.default.removeItem(at: plistFile)
            completion(error)
        }
    }

    static func uninstall(completion: @escaping (String?) -> Void) {
        runPrivileged(FanHelperInstallScript.uninstall(), completion: completion)
    }

    /// osascript in a subprocess, off the main thread: the password dialog can sit open for as long as
    /// the user likes, and the popover must stay responsive meanwhile.
    private static func runPrivileged(_ shell: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", FanHelperInstallScript.privileged(shell)]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            var message: String?
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    // -128 is AppleScript's "User canceled." — not an error worth a red line.
                    message = text.contains("-128") ? "Cancelled." : text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async { completion(message) }
        }
    }
}
