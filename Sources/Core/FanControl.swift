// FanControl.swift — the wire protocol between the app and the root fan helper, and the arithmetic
// both sides apply to a requested speed.
//
// It lives in Core for a reason beyond testability: this file is compiled into TWO binaries. The app
// builds it as part of Sources/, and build_app.sh compiles it again alongside Helper/*.swift for
// local.statsbar.fanhelper. One definition of every command and every limit check means the app and
// the daemon cannot disagree about what a line means — a disagreement that would otherwise surface as
// a fan the user asked to slow down being driven somewhere else by a process running as root.
//
// The protocol is one ASCII line per command and one per reply, deliberately dull: it is spoken over
// a Unix socket only the installing user can open, and a format that `nc -U` can drive by hand is
// worth more here than anything a binary encoding would save.

import Foundation

/// Timing shared by both ends of the connection.
enum FanControlTiming {
    /// How often the app pings while any fan is overridden. Well inside `watchdog` so a single late
    /// tick — a busy main thread, a slow socket write — never trips it.
    static let pingInterval: TimeInterval = 2

    /// Silence after which the helper gives up on the app and hands every fan back to the SMC. This is
    /// the guard for a HUNG app: a crashed one closes its socket and is caught immediately, but a hung
    /// one keeps the socket open and would otherwise pin the fans at whatever it last asked for.
    static let watchdog: TimeInterval = 10
}

/// One request from the app to the helper.
enum FanCommand: Equatable {
    /// Asks for the helper's protocol version — the app's way of learning the helper is up at all.
    case version
    /// Keeps the watchdog fed. Carries no state; any command resets the watchdog, this one just has
    /// no other effect.
    case ping
    /// Puts one fan in manual mode at `rpm`. The helper clamps to that fan's own limits.
    case set(fan: Int, rpm: Double)
    /// Every fan to its own ceiling (`F<n>Mx`).
    case max
    /// Every fan back under SMC control.
    case auto

    /// Fan indices the protocol accepts. FNum is a `ui8 ` and SMC.readFans caps its loop at 64, so
    /// nothing outside this range names a real fan; rejecting it at parse time keeps a stray index from
    /// ever being formatted into an SMC key name.
    static let fanIndices = 0..<64

    var line: String {
        switch self {
        case .version: return "version"
        case .ping: return "ping"
        case let .set(fan, rpm): return "set \(fan) \(Int(rpm.rounded()))"
        case .max: return "max"
        case .auto: return "auto"
        }
    }

    /// Parses one line (without its newline). nil for anything that is not exactly one of the forms
    /// `line` produces — the helper answers nil with an error and does nothing, so a malformed request
    /// can never reach an SMC write.
    init?(line: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        switch (parts.first, parts.count) {
        case ("version", 1): self = .version
        case ("ping", 1): self = .ping
        case ("max", 1): self = .max
        case ("auto", 1): self = .auto
        case ("set", 3):
            guard let fan = Self.wholeNumber(parts[1]), Self.fanIndices.contains(fan),
                  let rpm = Self.wholeNumber(parts[2]) else { return nil }
            self = .set(fan: fan, rpm: Double(rpm))
        default:
            return nil
        }
    }

    /// A field of ASCII digits only, as `line` writes it. Not a bare Int(String): that also accepts a
    /// leading "+" or "-", so it would take "+3000" — a form nothing here produces. Accepting only what
    /// `line` emits keeps the parser exactly as wide as the protocol. Overlong runs still come back nil,
    /// because Int(String) refuses to overflow.
    private static func wholeNumber(_ field: Substring) -> Int? {
        guard !field.isEmpty, field.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(field)
    }
}

/// One reply from the helper to the app.
enum FanReply: Equatable {
    case ok
    case version(String)
    case error(String)

    var line: String {
        switch self {
        case .ok: return "ok"
        case let .version(v): return "version \(v)"
        // Newlines would split one reply into two on the wire and desynchronise every reply after it.
        case let .error(message): return "error " + message.replacingOccurrences(of: "\n", with: " ")
        }
    }

    init?(line: String) {
        if line == "ok" {
            self = .ok
        } else if line.hasPrefix("version "), line.count > "version ".count {
            self = .version(String(line.dropFirst("version ".count)))
        } else if line.hasPrefix("error ") {
            self = .error(String(line.dropFirst("error ".count)))
        } else {
            return nil
        }
    }
}

enum FanProtocol {
    /// Bumped when a command or reply changes meaning. The app refuses to drive a helper reporting
    /// anything else and offers to update it instead.
    static let version = "1"

    /// The launchd label, and the helper's file name under /Library/PrivilegedHelperTools.
    static let helperLabel = "local.statsbar.fanhelper"

    /// Where the helper listens. /var/run because it is root-owned and cleared at boot, so a stale
    /// socket from a previous boot cannot be mistaken for a live helper.
    static let socketPath = "/var/run/statsbar-fan.sock"

    /// The reply to a `ping` when no fan is overridden. The app only pings while it believes one is,
    /// so this means the helper handed the fans back on its own (the watchdog fired, or the Mac slept)
    /// and the app's mode control is stale.
    static let notOverridden = "fans are back under automatic control"
}

enum FanTarget {
    /// `rpm` clamped into the fan's own `[minimum, maximum]`, or nil when no safe target exists.
    ///
    /// nil — rather than a best guess — whenever the limits cannot be trusted: either is non-finite or
    /// negative, or `maximum <= minimum`. The SMC is asked for those limits as `flt ` and SMC.readFloat
    /// already drops non-finite reads, but this runs in the root helper against values it read itself,
    /// and a target computed from a garbage ceiling is a write to real hardware. Refusing costs one
    /// command; the app reports it and falls back to Auto.
    static func clamped(rpm: Double, minimum: Double, maximum: Double) -> Double? {
        guard rpm.isFinite, minimum.isFinite, maximum.isFinite,
              minimum >= 0, maximum > minimum else { return nil }
        return Swift.min(maximum, Swift.max(minimum, rpm))
    }

    /// The per-fan targets Max mode writes: each fan's own ceiling, for every fan whose limits pass
    /// `clamped`'s checks. Ceilings differ per fan (5779 and 6241 rpm on the M1 Pro this was written
    /// on), which is why Max is not a single number.
    static func maxTargets(_ limits: [(fan: Int, minimum: Double, maximum: Double)]) -> [(fan: Int, rpm: Double)] {
        limits.compactMap { l in
            clamped(rpm: l.maximum, minimum: l.minimum, maximum: l.maximum).map { (l.fan, $0) }
        }
    }
}
