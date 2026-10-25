// FanHelperInstallScript.swift — the text FanHelperInstaller hands to `osascript … with administrator
// privileges`: the shell commands that install or remove the fan helper, and the launchd plist.
//
// Pure strings, and in Core for that reason alone: this is the one piece of StatsBar that runs as
// root on the user's say-so, and what it runs is assembled from a path the app does not control —
// the bundle can live anywhere, under any name, including one with a quote in it. Two layers of
// quoting stand between that path and /bin/sh (the shell's, then AppleScript's string literal around
// the whole command), and getting either wrong runs part of a file name as a root command. A test can
// pin that; a string built inline in the installer could not be reached by one.

import Foundation

enum FanHelperInstallScript {
    static let installedBinary = "/Library/PrivilegedHelperTools/\(FanProtocol.helperLabel)"
    static let installedPlist = "/Library/LaunchDaemons/\(FanProtocol.helperLabel).plist"
    static let logPath = "/var/log/statsbar-fanhelper.log"

    /// `s` as one single-quoted /bin/sh word. Inside single quotes nothing is special except the quote
    /// itself, which is closed, emitted escaped, and reopened.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `s` as an AppleScript string literal. Backslash first, so the quotes' own escapes are not
    /// themselves escaped again.
    static func appleScriptLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The whole AppleScript for one privileged shell command — the argument to `osascript -e`.
    static func privileged(_ shell: String) -> String {
        "do shell script \(appleScriptLiteral(shell)) with administrator privileges"
    }

    /// The launchd job. `--uid` is the only user the helper will accept a connection from.
    static func plist(uid: UInt32) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>              <string>\(FanProtocol.helperLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(installedBinary)</string>
                <string>--uid</string>
                <string>\(uid)</string>
            </array>
            <key>RunAtLoad</key>          <true/>
            <key>KeepAlive</key>          <true/>
            <key>StandardErrorPath</key>  <string>\(logPath)</string>
        </dict>
        </plist>

        """
    }

    /// Commands joined with "; " rather than newlines so the script survives AppleScript's literal
    /// unchanged; `set -e` makes any failed step fail the whole install, which osascript reports.
    ///
    /// The old job is booted out first so an update replaces a running helper — whose SIGTERM handler
    /// hands the fans back on the way out. `bootstrap` is retried once because it can briefly fail
    /// with an I/O error while launchd is still tearing the previous instance down.
    static func install(bundledHelper: String, plistFile: String) -> String {
        let label = FanProtocol.helperLabel
        return [
            "set -e",
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 0755 \(shellQuoted(bundledHelper)) \(shellQuoted(installedBinary))",
            "/usr/bin/install -o root -g wheel -m 0644 \(shellQuoted(plistFile)) \(shellQuoted(installedPlist))",
            "/bin/launchctl bootstrap system \(shellQuoted(installedPlist)) || { /bin/sleep 1; /bin/launchctl bootstrap system \(shellQuoted(installedPlist)); }",
        ].joined(separator: "; ")
    }

    static func uninstall() -> String {
        [
            "/bin/launchctl bootout system/\(FanProtocol.helperLabel) 2>/dev/null || true",
            "/bin/rm -f \(shellQuoted(installedPlist)) \(shellQuoted(installedBinary))",
        ].joined(separator: "; ")
    }
}
