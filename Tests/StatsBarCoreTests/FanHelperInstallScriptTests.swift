// FanHelperInstallScriptTests.swift — the quoting between a bundle path and a root shell.
//
// The failure guarded against is a file name executing as a command: the app can be renamed or moved
// anywhere, and the install script runs as root. Each test below feeds a path that would break out of
// a naively quoted script and checks it comes back as inert text. The decoding helpers are the
// inverse of what /bin/sh and AppleScript do with the result, so the round trip is the real claim.

import Testing
@testable import StatsBarCore

@Suite("Fan helper install script")
struct FanHelperInstallScriptTests {

    /// What /bin/sh makes of a word built only from single-quoted runs and \' escapes — the only shape
    /// shellQuoted emits.
    private func shellUnquote(_ word: String) -> String? {
        var out = ""
        var i = word.startIndex
        while i < word.endIndex {
            if word[i] == "'" {
                guard let close = word[word.index(after: i)...].firstIndex(of: "'") else { return nil }
                out += word[word.index(after: i)..<close]
                i = word.index(after: close)
            } else if word[i] == "\\", word.index(after: i) < word.endIndex {
                out.append(word[word.index(after: i)])
                i = word.index(i, offsetBy: 2)
            } else {
                return nil   // an unquoted character: the shell would interpret it
            }
        }
        return out
    }

    private func appleScriptUnquote(_ literal: String) -> String? {
        guard literal.count >= 2, literal.first == "\"", literal.last == "\"" else { return nil }
        var out = ""
        var escaped = false
        for c in literal.dropFirst().dropLast() {
            if escaped { out.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { return nil }   // an unescaped quote would end the literal early
            else { out.append(c) }
        }
        return escaped ? nil : out
    }

    static let hostilePaths = [
        "/Applications/StatsBar.app/Contents/Resources/local.statsbar.fanhelper",
        "/Users/me/Apps/Stats Bar (copy).app/x",
        "/tmp/it's here/x",
        "/tmp/'; rm -rf ~; '/x",
        "/tmp/$(touch pwned)/`id`/x",
        "/tmp/a\"b\\c/x",
    ]

    @Test("shell quoting round-trips any path", arguments: hostilePaths)
    func shellRoundTrip(path: String) {
        #expect(shellUnquote(FanHelperInstallScript.shellQuoted(path)) == path)
    }

    @Test("AppleScript quoting round-trips any command", arguments: hostilePaths)
    func appleScriptRoundTrip(path: String) {
        let command = FanHelperInstallScript.install(bundledHelper: path, plistFile: "/tmp/p.plist")
        #expect(appleScriptUnquote(FanHelperInstallScript.appleScriptLiteral(command)) == command)
    }

    @Test("the install script names the bundled helper as one quoted word")
    func installQuotesSource() {
        let path = "/tmp/'; rm -rf ~; '/x"
        let script = FanHelperInstallScript.install(bundledHelper: path, plistFile: "/tmp/p.plist")
        #expect(script.contains(FanHelperInstallScript.shellQuoted(path)))
        #expect(script.hasPrefix("set -e; "))
    }

    @Test("the plist runs the installed binary for the given user only")
    func plistArguments() {
        let plist = FanHelperInstallScript.plist(uid: 501)
        #expect(plist.contains("<string>\(FanHelperInstallScript.installedBinary)</string>"))
        #expect(plist.contains("<string>--uid</string>"))
        #expect(plist.contains("<string>501</string>"))
    }
}
