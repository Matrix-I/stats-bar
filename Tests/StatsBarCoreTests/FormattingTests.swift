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
        (UInt64(1_073_741_824), "1.00 GB"),   // exactly 1 GiB — flips to GB
        (UInt64(3_028_287_488), "2.82 GB"),
    ])
    func fmtProcessMemoryBoundary(input: UInt64, expected: String) {
        #expect(fmtProcessMemory(input) == expected)
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
        (5_000_000_000_000.0, "5000", "GB/s"),   // no unit beyond GB/s exists, so it stops there
        (-42.0, "0", "B/s"),                 // negative clamps instead of printing "-0"
    ])
    func fmtRatePartsSplit(rate: Double, value: String, unit: String) {
        let parts = fmtRateParts(rate)
        #expect(parts.value == value)
        #expect(parts.unit == unit)
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
}
