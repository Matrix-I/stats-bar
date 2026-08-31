// ProcessList.swift — shared helper for the TOP PROCESSES tables in the CPU and RAM popovers:
// resolving a pid to a display name + app icon. Used by both CPUReader and MemoryReader so the two
// tables identify processes identically.

import Foundation
import AppKit

enum ProcessList {
    /// A GUI application's localized name and icon (e.g. "Google Chrome" + its icon) when the PID
    /// owns an NSRunningApplication; otherwise the `ps` accounting name and no icon, for the
    /// daemons/helpers that have none (the view draws a generic placeholder for those).
    ///
    /// Choosing between the names an NSRunningApplication offers is ProcessDisplayName's job, in
    /// Sources/Core, because it is a decision with a wrong answer that looks right — see the comment
    /// there. This function is the adapter: it pulls the candidates off AppKit and hands them over.
    static func identity(pid: Int, fallback comm: String) -> (name: String, icon: NSImage?) {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return (comm, nil) }
        let name = ProcessDisplayName.resolve(localizedName: app.localizedName,
                                              isBundled: app.bundleIdentifier != nil,
                                              executableName: app.executableURL?.lastPathComponent,
                                              accountingName: comm)
        return (name, app.icon)
    }
}
