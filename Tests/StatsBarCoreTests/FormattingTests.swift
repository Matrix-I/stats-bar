// FormattingTests.swift — the value formatters behind every number in the panels.
//
// Worth pinning down because the bugs here are silent: a wrong divisor still prints a plausible
// number, and "free RAM" reading 3 GB high is exactly the kind of thing that shipped once already.
// The cases below are chosen to fail if a unit base changes (decimal vs binary), if a rounding
// threshold moves, or if a clamp against negative input is dropped — not to re-state the code.

import Testing
import SwiftUI
@testable import StatsBarCore

@Suite("Formatting")
struct FormattingTests {

    // MARK: fmtBytes — DECIMAL units, matching how macOS reports network transfer

    @Test("fmtBytes divides by 1000, not 1024")
    func fmtBytesUsesDecimalUnits() {
        // The load-bearing pair: one mebibyte must NOT be what reads "1.0 MB". 1_048_576 ÷ 1000² is
        // 1.048…, so a decimal formatter prints 1.0 MB for BOTH values below, while a binary one would
        // print it only for 1_048_576. Either case alone looks right; only the pair distinguishes them.
        #expect(fmtBytes(1_000_000) == "1.0 MB")
        #expect(fmtBytes(1_048_576) == "1.0 MB")
        #expect(fmtBytes(1_073_741_824) == "1.1 GB")   // 1 GiB, in decimal GB
    }

    @Test("fmtBytes unit boundaries", arguments: [
        (UInt64(0), "0 bytes"),
        (UInt64(999), "999 bytes"),          // last value with no decimal
        (UInt64(1000), "1.0 KB"),            // first promoted value
        (UInt64(58_500_000), "58.5 MB"),
        (UInt64(999_949), "999.9 KB"),       // last value that still reads in KB
        (UInt64(999_950), "1.0 MB"),         // half a printed digit later the unit must change
    ])
    func fmtBytesBoundaries(input: UInt64, expected: String) {
        #expect(fmtBytes(input) == expected)
    }

    @Test("fmtBytes stops at TB instead of running off the unit table")
    func fmtBytesClampsToTerabytes() {
        // The while loop is bounded by units.count - 1; without that bound this indexes out of range.
        #expect(fmtBytes(UInt64.max).hasSuffix(" TB"))
    }

    // MARK: fmtGB / fmtProcessMemory — BINARY units, matching how macOS labels RAM

    @Test("fmtGB uses binary gibibytes")
    func fmtGBUsesBinaryUnits() {
        #expect(fmtGB(17_179_869_184) == "16.00 GB")   // a 16 GiB Mac must read "16.00"
        #expect(fmtGB(1_000_000_000) == "0.93 GB")     // a decimal GB is only 0.93 GiB
        #expect(fmtGB(0) == "0.00 GB")
    }

    @Test("fmtProcessMemory switches unit at exactly one gibibyte", arguments: [
        (UInt64(0), "0 MB"),
        (UInt64(1_071_644_672), "1022 MB"),   // 1022 MiB — still MB
        (UInt64(1_073_217_535), "1023 MB"),   // last MiB figure that rounds below 1024
        (UInt64(1_073_217_536), "1.00 GB"),   // 1023.5 MiB rounds TO 1024, so the unit changes here
        (UInt64(1_073_741_823), "1.00 GB"),   // one byte under a gibibyte
        (UInt64(1_073_741_824), "1.00 GB"),   // exactly 1 GiB
        (UInt64(3_028_287_488), "2.82 GB"),
    ])
    func fmtProcessMemoryBoundary(input: UInt64, expected: String) {
        #expect(fmtProcessMemory(input) == expected)
    }

    @Test("no scaling formatter prints a figure its own unit rules out")
    func unitIsChosenAfterRounding() {
        // One rule, three functions: the unit follows the value AS PRINTED. Each input here sits in the
        // window where the raw value is below the promotion threshold but the printed one is not, and
        // each used to produce a reading the function's own rules forbid — "1024 MB" from a branch that
        // stops at a gibibyte, "1000.0 KB" and "1000 B/s" from tables whose next unit begins at 1000.
        #expect(fmtProcessMemory(1_073_217_536) == "1.00 GB")   // 1023.5 MiB; was "1024 MB"
        #expect(fmtBytes(999_950) == "1.0 MB")                  // was "1000.0 KB"
        #expect(fmtBytes(999_999_999) == "1.0 GB")              // was "1000.0 MB"

        let slowLink = fmtRateParts(999.6)
        #expect(slowLink.value == "1")                          // was "1000"
        #expect(slowLink.unit == "KB/s")                        // …of "B/s"

        let fastLink = fmtRateParts(999_600)
        #expect(fastLink.value == "1.0")                        // was "1000"
        #expect(fastLink.unit == "MB/s")                        // …of "KB/s"
    }

    // MARK: fmtUptime — coarse, and singular/plural correct

    @Test("fmtUptime picks the right two units", arguments: [
        (0.0, "0 minutes"),
        (59.0, "0 minutes"),                  // sub-minute boot
        (3599.0, "59 minutes"),               // last minutes-only value
        (3600.0, "1 hour, 0 minutes"),        // hours appear
        (86_399.0, "23 hours, 59 minutes"),   // last hours+minutes value
        (86_400.0, "1 day, 0 hours"),         // days take over, minutes disappear
        (320_400.0, "3 days, 17 hours"),
    ])
    func fmtUptimeUnits(seconds: Double, expected: String) {
        #expect(fmtUptime(seconds) == expected)
    }

    @Test("fmtUptime singularises 1 and clamps negative input")
    func fmtUptimeSingularAndClamp() {
        #expect(fmtUptime(60) == "1 minute")            // not "1 minutes"
        #expect(fmtUptime(90_000) == "1 day, 1 hour")   // both units singular
        // A clock that jumped backwards must not print "-1 minutes"; Int(max(0, …)) prevents it.
        #expect(fmtUptime(-1000) == "0 minutes")
    }

    // MARK: fmtMinutes — the battery time-remaining row

    @Test("fmtMinutes zero-pads the minutes", arguments: [
        (0, "0h 00m"),
        (5, "0h 05m"),      // "0h 5m" would misalign the monospaced column
        (65, "1h 05m"),
        (600, "10h 00m"),
    ])
    func fmtMinutesPadding(input: Int, expected: String) {
        #expect(fmtMinutes(input) == expected)
    }

    @Test("fmtMinutes clamps negative input like fmtUptime does")
    func fmtMinutesClampsNegative() {
        // Unclamped, the sign appears twice — "-1h -30m" — because the hours and the remainder are
        // signed independently. The two BatteryDetailView call sites filter to 1..<65535, so this is
        // cover for the next caller rather than a live fix; the point is that the two time formatters
        // in this file now agree about negative input instead of one clamping and the other not.
        #expect(fmtMinutes(-1) == "0h 00m")
        #expect(fmtMinutes(-90) == "0h 00m")
    }

    // MARK: fmtRate / fmtRateParts — live throughput

    @Test("fmtRate appends /s and survives a negative rate")
    func fmtRateHandlesNegativeInput() {
        #expect(fmtRate(0) == "0 bytes/s")
        #expect(fmtRate(1_200_000) == "1.2 MB/s")
        // Not cosmetic: fmtRate converts to UInt64, so a negative rate — which a counter reset can
        // produce — would TRAP without the max(0, …) clamp rather than merely print something wrong.
        #expect(fmtRate(-1) == "0 bytes/s")
    }

    @Test("fmtRateParts rounds whole up to KB/s and keeps a decimal for small MB/s", arguments: [
        (0.0, "0", "B/s"),
        (1500.0, "2", "KB/s"),               // KB/s rounds to whole
        (1_500_000.0, "1.5", "MB/s"),        // small MB/s keeps one decimal…
        (15_000_000.0, "15", "MB/s"),        // …but 10 MB/s and up doesn't
        (9_999_999.0, "10.0", "MB/s"),       // just under the switch: one decimal, rendered "10.0"
        (10_000_000.0, "10", "MB/s"),        // and exactly on it: whole. `value < 10`, not <=
        (5_000_000_000_000.0, "5000", "GB/s"),   // no unit beyond GB/s exists, so it stops there
        (-42.0, "0", "B/s"),                 // negative clamps instead of printing "-0"
    ])
    func fmtRatePartsSplit(rate: Double, value: String, unit: String) {
        let parts = fmtRateParts(rate)
        #expect(parts.value == value)
        #expect(parts.unit == unit)
    }

    // MARK: displayVersion — dev builds show "dev", not a placeholder release number

    @Test("displayVersion shows dev for a SNAPSHOT build, v-prefixed otherwise", arguments: [
        ("2.13.0-SNAPSHOT", "dev"),
        ("2.12.3", "v2.12.3"),
        ("2.12.3-SNAPSHOT", "dev"),
    ])
    func displayVersionHidesTheSnapshotNumber(input: String, expected: String) {
        // The number in front of "-SNAPSHOT" is a placeholder CLAUDE.md itself calls "a judgement call,
        // not a formula" — it might ship as the next minor or collapse to a hotfix patch, and a dev
        // build can be either depending on which branch it was cut from. Showing "dev" says only what
        // is certain; showing the placeholder number would state a guess as if it were settled.
        #expect(displayVersion(input) == expected)
    }

    // MARK: flagEmoji — the public-IP country row

    @Test("flagEmoji maps letters to regional indicators")
    func flagEmojiMapsLetters() {
        #expect(flagEmoji("VN") == "🇻🇳")
        #expect(flagEmoji("CH") == "🇨🇭")
        #expect(flagEmoji("vn") == "🇻🇳")   // lowercase input still works
    }

    @Test("flagEmoji rejects anything that is not two ASCII letters", arguments: [
        "", "V", "USA", "V1", "--", "ÜÜ",
    ])
    func flagEmojiRejectsBadInput(code: String) {
        // Returning "" rather than garbage matters: these codes come off the network, and a stray
        // value must leave the row blank instead of printing two boxes of Unicode debris.
        #expect(flagEmoji(code) == "")
    }

    // MARK: healthColor — battery health thresholds

    @Test("healthColor thresholds are inclusive at 80 and 60", arguments: [
        (100.0, Color.green),
        (80.0, Color.green),     // boundary is inclusive
        (79.9, Color.orange),
        (60.0, Color.orange),    // boundary is inclusive
        (59.9, Color.red),
        (0.0, Color.red),
    ])
    func healthColorThresholds(percent: Double, expected: Color) {
        #expect(healthColor(percent) == expected)
    }

    // MARK: menuBarRate — the formatter the earlier sweep could not see

    @Test("menuBarRate promotes before the printed figure reaches four digits", arguments: [
        (999.4, "999 B/s"),      // last value that still prints in bytes
        (999.5, "1 KB/s"),       // half a printed digit later, and it must have promoted
        (999_499.0, "999 KB/s"),
        (999_500.0, "1.0 MB/s"),
        (999_949_999.0, "999.9 MB/s"),
        (999_950_000.0, "1.0 GB/s"),
    ])
    func menuBarRateBoundaries(input: Double, expected: String) {
        // These six are the whole point of moving this function into Core. Each pair straddles the
        // threshold where the OLD code — which compared against a flat 1000 after choosing the band —
        // printed "1000 B/s", "1000 KB/s" and "1000.0 MB/s": a four-digit figure in a unit its own
        // banding says should have become the next one up. The value below each boundary has to keep
        // its unit, or the fix has merely moved the fault one band down.
        #expect(menuBarRate(input) == expected)
    }

    @Test("menuBarRate keeps the ordinary readings unchanged", arguments: [
        (0.0, "0 B/s"),
        (512.0, "512 B/s"),
        (1000.0, "1 KB/s"),
        (58_500_000.0, "58.5 MB/s"),
        (2_400_000_000.0, "2.4 GB/s"),
    ])
    func menuBarRateOrdinaryValues(input: Double, expected: String) {
        // The threshold move must not shift anything a person actually sees. This is a menu-bar label
        // that is on screen permanently, so a change of unit or precision in the normal range would be
        // far more noticeable than the edge case being fixed.
        #expect(menuBarRate(input) == expected)
    }

    @Test("menuBarRate clamps a negative rate rather than printing a minus sign")
    func menuBarRateClampsNegative() {
        // A counter that wrapped or an interface that reset can hand the tracker a negative delta. In
        // the menu bar a "-2 KB/s" reads as a direction, not an error.
        #expect(menuBarRate(-1) == "0 B/s")
        #expect(menuBarRate(-1e9) == "0 B/s")
    }

    // MARK: roundedInt — the conversion that used to be a crash

    @Test("roundedInt rounds half away from zero, like the Int(v.rounded()) it replaced", arguments: [
        (0.0, 0), (0.4, 0), (0.5, 1), (1.5, 2), (2334.4, 2334), (2334.5, 2335),
        (-0.5, -1), (-1.4, -1), (-1.5, -2),
    ])
    func roundedIntMatchesTheOldRounding(input: Double, expected: Int) {
        // The point of the replacement was to stop it TRAPPING, not to change what it prints, so the
        // ordinary cases have to keep giving the same answers a bare Int(v.rounded()) gave — including
        // .toNearestOrAwayFromZero at the halves, which is `rounded()`'s default and not banker's
        // rounding. A guard that quietly shifted every reading by one would be a worse bug than the
        // crash it fixed, and nothing on screen would look wrong.
        #expect(roundedInt(input) == expected)
    }

    @Test("roundedInt survives the values that halt the process", arguments: [
        Double.nan, .signalingNaN, .infinity, -.infinity,
        1e300, -1e300, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
        9_223_372_036_854_775_808.0,      // exactly 2^63: Double(Int.max) rounded up, so `v < Double(Int.max)` admits it
        -9_223_372_036_854_775_809.0,
    ])
    func roundedIntSaturatesInsteadOfTrapping(input: Double) {
        // Every argument here CRASHES `Int(input.rounded())` outright — this is not a test that some
        // number comes out prettier. It is why the app can read an SMC key whose four bytes happen to
        // be a NaN pattern, or a throughput rate divided by an elapsed time that rounded to nothing,
        // and print something wrong instead of terminating on the next popover open.
        //
        // A swift-testing #expect cannot catch a trap: the process dies and the run reports nothing at
        // all. So the assertion is simply that control reaches the next line, and the failure mode of
        // a regression here is a suite that dies rather than one that goes red. Worth knowing when
        // this file next fails in an unfamiliar way.
        let out = roundedInt(input)
        #expect(out >= Int.min && out <= Int.max)
    }

    @Test("roundedInt saturates towards the sign it came from")
    func roundedIntSaturatesWithSign() {
        // Direction matters and is the part a careless rewrite gets wrong: returning Int.max for a
        // hugely NEGATIVE reading would turn an obviously broken sensor into a plausible-looking
        // maximum. Non-finite input has no sign to honour, so it lands on zero.
        #expect(roundedInt(1e300) == Int.max)
        #expect(roundedInt(-1e300) == Int.min)
        #expect(roundedInt(.nan) == 0)
        #expect(roundedInt(.infinity) == Int.max)
        #expect(roundedInt(-.infinity) == Int.min)
    }

    @Test("roundedInt keeps the largest values that genuinely fit")
    func roundedIntKeepsRepresentableExtremes() {
        // The boundary the saturation must not overshoot: 2^63 − 1024 is the largest Double below
        // Int.max, and it converts exactly. Clamping it away would be a silent off-by-a-lot on the one
        // input that did not need clamping.
        let largestExact = 9_223_372_036_854_774_784.0   // 2^63 − 1024
        #expect(roundedInt(largestExact) == Int(largestExact))
        #expect(roundedInt(-largestExact) == Int(-largestExact))
    }
}
