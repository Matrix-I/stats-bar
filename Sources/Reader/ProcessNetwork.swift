// ProcessNetwork.swift — one sweep of per-process network counters, from `nettop`.
//
// Everything interesting about reading this is in Sources/Core/NettopOutput, which is where the
// parsing lives and where the tests can reach it. What is left here is the subprocess: the path, the
// arguments and the two ways the read can come back with nothing useful.
//
// Two of the arguments are load-bearing rather than tidying:
//
//   • `-n` disables address-to-name resolution, and it is the difference between 30 ms and 5.1 s.
//     Measured on this machine, repeatedly: without it nettop blocks on reverse DNS for every remote
//     endpoint before printing a single row, which is far past anything a 1 Hz reader can spend and
//     past DeviceTool's own timeout on a slow resolver.
//   • No `-t` filter, deliberately. `-t wifi -t wired` is just as fast and looks like the right
//     narrowing, but it drops every socket that is not bound to a physical interface — which on a
//     machine running a VPN is all of them. Measured with a download in flight: curl was absent from
//     the wifi/wired list entirely and present in the unfiltered one, with the tunnel daemon holding
//     the only visible traffic. The unfiltered sweep is what shows real applications.
//
// The VPN daemon that carries that traffic still appears as its own row, counting every byte a second
// time. That is nettop reporting what is true — the daemon really did move those bytes — and the
// table shows it rather than guessing which processes are tunnels.

import Foundation

enum ProcessNetwork {
    /// Part of the base system since long before this app's macOS 13 floor, so a missing binary means
    /// something unusual rather than an old release — still checked, because the alternative is an
    /// empty table with nothing to say for itself.
    static let toolPath = "/usr/bin/nettop"

    struct Reading {
        var samples: [ProcessNetworkSample] = []
        /// Why the table is empty, phrased for the popover; nil when the read succeeded (which
        /// includes succeeding with nothing to report).
        var status: String?
    }

    /// One sweep. Blocking — call it off the main thread.
    static func read() -> Reading {
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            return Reading(status: "nettop isn’t available on this Mac, so per-process traffic can’t be measured.")
        }
        // A one-shot logging sample: -P per-process summaries only, -L 1 one CSV sample then exit,
        // -x raw byte counts rather than human-readable suffixes, -n no DNS, -J only the two columns
        // NettopOutput looks for. Well inside DeviceTool's timeout at ~30 ms.
        guard let data = DeviceTool.run(toolPath,
                                        ["-P", "-L", "1", "-x", "-n",
                                         "-J", "\(NettopOutput.bytesInColumn),\(NettopOutput.bytesOutColumn)"]),
              let text = String(data: data, encoding: .utf8) else {
            return Reading(status: "Couldn’t read per-process traffic from nettop.")
        }
        // nil, not empty: the header did not carry the columns we asked for. An older nettop without
        // -J would land here (it exits non-zero and is caught above), and so would a future one that
        // renames a column. Either way the honest answer is that this build cannot read the output —
        // not a table of zeroes, which would look like a quiet network.
        guard let samples = NettopOutput.parse(text) else {
            return Reading(status: "nettop returned a format this version of StatsBar doesn’t recognise.")
        }
        return Reading(samples: samples)
    }
}
