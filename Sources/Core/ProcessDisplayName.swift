// ProcessDisplayName.swift — which of the several names a macOS process has belongs in a TOP
// PROCESSES row. Pure: the candidate strings in, the one to draw out.
//
// The CPU, RAM and Network tables all render a name beside a number in a 300 pt popover, and until
// now they took NSRunningApplication.localizedName whenever the pid owned one. That is right for a
// bundled application and wrong for everything else, because for an unbundled process localizedName
// is not a curated name at all — it is the process title, and a process may set that to whatever it
// likes. Node does, to its whole command line. Measured on a live process:
//
//   localizedName    "npm exec @redocly/cli@2.44.2 bundle /Users/linh.nguyen/Desktop/mesoneer-
//                     projects/mideal/ubiid-openapi-spec/signeer-signing-workflow-integration.
//                     internal.yaml -o /tmp/claude-501/swi-publish.GQhhleDQ/source.json"   (209 ch)
//   bundleIdentifier  nil
//   executableURL     .../nodejs/22.20.0/bin/node
//   ps -c -o comm     "source.json"
//
// The row does not break — ProcessRow truncates to one line — it just stops identifying anything.
//
// The obvious repair is to fall back to the accounting name when localizedName looks unreasonable,
// and the fourth line above is why that repair is wrong. macOS derives p_comm from the LAST PATH
// COMPONENT of the process title, so a title ending in a file path leaves the accounting name as
// "source.json": shorter, still not the process, and now actively misleading — it reads as a file.
//
// So the rule keys off whether the process is bundled, which is exactly the question "does
// localizedName mean anything?". A bundled app's name comes from its Info.plist and is what the user
// calls it; an unbundled process's does not, and its executable's filename is both stable and what
// Activity Monitor shows for the same process. Length is deliberately not a factor: the longest
// bundled name on the machine this was written on is the 64-character "QuickLookUIService (Open and
// Save Panel Service (Google Chrome))", which is legitimate and which any threshold low enough to
// catch a command line would also discard.

import Foundation

enum ProcessDisplayName {
    /// Picks the name a process table should show.
    ///
    /// - Parameters:
    ///   - localizedName: NSRunningApplication.localizedName, or nil when the pid owns no application.
    ///   - isBundled: whether that application has a bundle identifier — i.e. whether `localizedName`
    ///     is a name someone chose, rather than the process title.
    ///   - executableName: the last path component of the executable, "node" for the case above.
    ///   - accountingName: the caller's own fallback (`ps -o comm`, or nettop's process name), used
    ///     only when nothing better exists.
    ///
    /// Every candidate is checked for emptiness rather than merely for nil. AppKit hands back an empty
    /// localizedName for some short-lived processes, and an empty row is worse than a crude one — it
    /// leaves a number on screen attached to nothing at all.
    static func resolve(localizedName: String?,
                        isBundled: Bool,
                        executableName: String?,
                        accountingName: String) -> String {
        // A bundled app: localizedName is the Info.plist name and beats every other candidate.
        if isBundled, let name = nonEmpty(localizedName) { return name }
        // Unbundled: the executable's filename is the honest answer, and the one Activity Monitor uses.
        if let name = nonEmpty(executableName) { return name }
        // No executable path — fall back the way this code always did. For an unbundled process this
        // is the process title, which is the string the whole file exists to avoid; it is still
        // preferable to an empty row, and it is reached only when macOS told us nothing else.
        if let name = nonEmpty(accountingName) { return name }
        return nonEmpty(localizedName) ?? "—"
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
