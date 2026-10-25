// FanControlTests.swift — the protocol and the target arithmetic the root fan helper acts on.
//
// What these guard against is a write to real hardware that nobody asked for. The helper runs as root
// and turns a parsed line straight into SMC writes, so a parser that accepts a line it should not, or
// a clamp that lets a garbage limit through, is not a cosmetic bug — it is a fan pinned at a speed the
// user never chose. The limits used below are this M1 Pro's own (fan 0: 1200–5779 rpm).

import Testing
@testable import StatsBarCore

@Suite("Fan control")
struct FanControlTests {

    // MARK: commands

    @Test("every command survives a round trip", arguments: [
        FanCommand.version, .ping, .max, .auto, .set(fan: 0, rpm: 3000), .set(fan: 63, rpm: 0),
    ])
    func commandRoundTrip(command: FanCommand) {
        #expect(FanCommand(line: command.line) == command)
    }

    @Test("set rounds to whole rpm on the wire")
    func setRounds() {
        // The slider produces fractional values; the wire carries integers, and the parser refuses
        // anything else — so the rounding has to happen on the way out, not be left to chance.
        #expect(FanCommand.set(fan: 1, rpm: 2999.6).line == "set 1 3000")
    }

    @Test("malformed commands are rejected", arguments: [
        "", "Auto", "auto ", " auto", "auto now", "set", "set 0", "set 0 3000 1",
        "set -1 3000", "set 64 3000", "set 0 -5", "set 0 nan", "set 0 inf", "set 0 3e3",
        "set 0 +3000", "set 0 3000.5", "set  0 3000", "set x 3000",
    ])
    func malformedCommands(line: String) {
        #expect(FanCommand(line: line) == nil)
    }

    // MARK: replies

    @Test("every reply survives a round trip", arguments: [
        FanReply.ok, .version("1"), .error("F0Md is not writable"),
    ])
    func replyRoundTrip(reply: FanReply) {
        #expect(FanReply(line: reply.line) == reply)
    }

    @Test("an error message cannot split into two replies")
    func errorStaysOneLine() {
        let line = FanReply.error("first\nsecond").line
        #expect(!line.contains("\n"))
        #expect(FanReply(line: line) == .error("first second"))
    }

    @Test("unknown replies are rejected", arguments: ["", "OK", "version", "version ", "err x"])
    func malformedReplies(line: String) {
        #expect(FanReply(line: line) == nil)
    }

    // MARK: clamping

    @Test("targets are clamped into the fan's own range", arguments: [
        (500.0, 1200.0),      // below the floor
        (1200.0, 1200.0),     // at the floor
        (3000.0, 3000.0),     // inside
        (5779.0, 5779.0),     // at the ceiling
        (9000.0, 5779.0),     // above the ceiling
    ])
    func clampsIntoRange(rpm: Double, expected: Double) {
        #expect(FanTarget.clamped(rpm: rpm, minimum: 1200, maximum: 5779) == expected)
    }

    @Test("untrustworthy limits give no target", arguments: [
        (1200.0, 1200.0),               // empty range
        (5779.0, 1200.0),               // inverted
        (-100.0, 5779.0),               // negative floor
        (Double.nan, 5779.0),
        (1200.0, Double.nan),
        (1200.0, Double.infinity),
    ])
    func rejectsBadLimits(minimum: Double, maximum: Double) {
        // Every case here would still produce a finite, plausible-looking number from a bare min/max
        // clamp — the inverted range clamps 3000 to 1200, the infinite ceiling passes it through. That
        // is the failure: a believable target from limits the SMC never meant.
        #expect(FanTarget.clamped(rpm: 3000, minimum: minimum, maximum: maximum) == nil)
    }

    @Test("a non-finite request gives no target")
    func rejectsBadRequest() {
        #expect(FanTarget.clamped(rpm: .nan, minimum: 1200, maximum: 5779) == nil)
        #expect(FanTarget.clamped(rpm: .infinity, minimum: 1200, maximum: 5779) == nil)
    }

    // MARK: max

    @Test("max drives each fan to its own ceiling and skips unusable ones")
    func maxTargets() {
        let targets = FanTarget.maxTargets([
            (fan: 0, minimum: 1200, maximum: 5779),
            (fan: 1, minimum: 1200, maximum: 6241),
            (fan: 2, minimum: 1200, maximum: 0),     // a fan that published no usable ceiling
        ])
        #expect(targets.map(\.fan) == [0, 1])
        #expect(targets.map(\.rpm) == [5779, 6241])
    }
}
