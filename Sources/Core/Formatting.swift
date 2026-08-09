// Formatting.swift — small presentation helpers shared across the views.
//
// The scaling formatters below (fmtProcessMemory, fmtBytes, fmtRateParts) share one rule that is easy
// to get wrong: the unit has to be chosen from the value AS PRINTED, not from the raw one. Deciding the
// unit first and rounding inside it lets the top of each band round straight past the band, which is
// how this file used to print "1024 MB", "1000.0 KB" and "1000 B/s" — readings those units cannot have
// by the functions' own rules. Each threshold below is therefore 1000 (or 1024) minus half of the last
// digit that gets shown.

import SwiftUI

func healthColor(_ p: Double) -> Color {
    p >= 80 ? .green : (p >= 60 ? .orange : .red)
}

/// A measured Double → the Int a label prints.
///
/// Not a convenience. `Int(someDouble)` is a TRAPPING conversion, not a saturating one: it halts the
/// process on NaN, on ±infinity and on any magnitude past Int64's range. build_app.sh ships -O rather
/// than -Ounchecked, so that precondition is in the release binary, and `Int(v.rounded())` written
/// inline — which is how all fourteen of these sites used to read — is a crash rather than a silly
/// number. The same distinction CLAUDE.md draws about unsigned `-`, in the other direction.
///
/// Reachable because the values are sensor readings. The SMC decodes a `flt ` key by reinterpreting
/// four bytes as a Float32 (SMC.decode), so any key whose bytes are not a fan speed — a fan index the
/// machine does not have, a controller mid-reset, a key that means something else on another chip —
/// yields NaN or an exponent no RPM has. SMC.readFloat now refuses non-finite readings at the source,
/// which is the real fix; this is the second line, and it also covers the values that reach a view
/// from IOKit and CoreGraphics without passing through the SMC at all.
///
/// Applied at every such site rather than only the ones whose input is currently unprovable, because
/// the alternative is a reader re-deriving "can this divide by zero?" per call site, and getting it
/// right fourteen times running. Saturating rather than optional for the same reason: these are all
/// display sites, and an absurd number is visibly absurd and gets reported, while a row that quietly
/// vanishes looks like a Mac without that sensor.
func roundedInt(_ v: Double) -> Int {
    // NaN is the only input with no sign to honour, so it is the only one that lands on zero.
    // Infinity deliberately does NOT: it saturates like any other over-range value, because a fan row
    // reading 9223372036854775807 rpm is self-evidently a broken sensor, while the same row reading
    // "0 rpm" is a perfectly ordinary thing for a fan to do and nobody would ever report it.
    guard !v.isNaN else { return 0 }
    let r = v.rounded()
    // After rounding, `Int(exactly:)` can only fail for being out of range, so the sign picks the end
    // to saturate to. Written this way rather than comparing against Double(Int.max), which is not
    // representable as a Double and rounds UP to 2^63 — so the obvious `v < Double(Int.max)` admits
    // exactly the one value that still traps.
    if let exact = Int(exactly: r) { return exact }
    return r < 0 ? Int.min : Int.max
}

/// Minutes → "1h 05m" for the battery time-remaining rows. Clamped at zero, like fmtUptime: the two
/// call sites in BatteryDetailView already filter to 1..<65535, so this is defence for the next caller
/// rather than a live fix — but IOKit's time-to-full can read negative while its estimate settles, and
/// unclamped that prints "-1h -30m", with the minutes carrying a second sign.
func fmtMinutes(_ m: Int) -> String {
    let m = max(0, m)
    return "\(m / 60)h \(String(format: "%02d", m % 60))m"
}

/// Seconds-since-boot → a coarse human uptime like macOS Activity Monitor's ("3 days, 17 hours").
/// Days+hours once it's been up a day; hours+minutes below that; minutes for a fresh boot.
func fmtUptime(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    let days = s / 86400, hours = (s % 86400) / 3600, mins = (s % 3600) / 60
    func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
    if days > 0 { return "\(plural(days, "day")), \(plural(hours, "hour"))" }
    if hours > 0 { return "\(plural(hours, "hour")), \(plural(mins, "minute"))" }
    return plural(mins, "minute")
}

/// Bytes → "x.xx GB" using binary GiB (÷1024³), matching how macOS labels RAM (a 16 GiB Mac reads "16.00 GB").
func fmtGB(_ bytes: UInt64) -> String {
    String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
}

/// Bytes → "2.82 GB" / "843 MB" for the per-process memory column, using binary units (like the
/// rest of the RAM tab). GB with two decimals once it reaches a gibibyte; whole mebibytes below.
func fmtProcessMemory(_ bytes: UInt64) -> String {
    let mib = Double(bytes) / 1_048_576
    // `mib.rounded()`, not `mib`: whole mebibytes are printed, so everything from 1023.5 MiB up rounds
    // to "1024 MB" — which by this function's own rule is a gibibyte. A browser or Xcode sitting just
    // under 1 GiB lands in that half-mebibyte window routinely.
    return mib.rounded() >= 1024 ? String(format: "%.2f GB", mib / 1024)
                                 : String(format: "%.0f MB", mib)
}

/// Bytes → "55.8 MB" using decimal units (÷1000), matching how macOS reports network data transfer
/// (bytes, KB, MB, GB, TB). Kept separate from fmtGB, which uses binary GiB for RAM.
func fmtBytes(_ bytes: UInt64) -> String {
    let units = ["bytes", "KB", "MB", "GB", "TB"]
    // 999.95, not 1000: one decimal is printed, so that is where the printed figure would become
    // "1000.0". Below the KB band it makes no difference — a byte count has no fractional part — so one
    // threshold covers every band.
    let promoteAbove = 999.95
    var value = Double(bytes)
    var i = 0
    while value >= promoteAbove && i < units.count - 1 { value /= 1000; i += 1 }
    // Whole bytes read as integers; everything larger keeps one decimal (like Activity Monitor).
    return i == 0 ? "\(Int(value)) bytes" : String(format: "%.1f %@", value, units[i])
}

/// Bytes-per-second → "1.2 MB/s" for the live throughput rows.
///
/// `UInt64(someDouble)` traps exactly as `Int(someDouble)` does, and the rate is a byte delta divided
/// by an elapsed time this code does not control — so the one input that produces an impossible
/// magnitude is a sampling interval that rounds to almost nothing. roundedInt saturates instead.
func fmtRate(_ bytesPerSec: Double) -> String {
    fmtBytes(UInt64(max(0, roundedInt(bytesPerSec)))) + "/s"
}

/// Splits a bytes/sec rate into a big number and its unit ("2" + "KB/s") for the prominent
/// Download/Upload header. Whole numbers up to KB/s (like the reference design); one decimal for
/// small MB/s+ so a slow megabyte-range link still reads meaningfully.
func fmtRateParts(_ bytesPerSec: Double) -> (value: String, unit: String) {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    // 999.5, not 1000: near the top of a band this always prints a whole number (the one-decimal form
    // below only applies under 10), so half a unit is where the printed figure would become "1000".
    let promoteAbove = 999.5
    var value = max(0, bytesPerSec)
    var i = 0
    while value >= promoteAbove && i < units.count - 1 { value /= 1000; i += 1 }
    let valueStr: String
    switch i {
    case 0, 1: valueStr = String(roundedInt(value))                        // B/s, KB/s → whole
    default:   valueStr = value < 10 ? String(format: "%.1f", value)          // small MB/s+ → 1 dp
                                     : String(roundedInt(value))
    }
    return (valueStr, units[i])
}

/// Short bytes/sec for the menu bar: whole numbers up to KB/s, one decimal above, so the label stays
/// narrow enough to sit beside the other items. Not private — AppDelegate builds the network glyph's
/// image cache key from this string, so the glyph is redrawn only when the printed text changes
/// rather than on every sub-unit wobble.
///
/// It lived in Sources/View/MenuBar.swift until now, which is the only interesting thing about it:
/// the sweep that fixed exactly this defect in every formatter above never reached it, because the
/// sweep was over this file. So the menu bar spent that whole time able to print "1000 KB/s" and
/// "1000.0 MB/s" — readings its own banding says are a megabyte and a gigabyte — while the popover
/// rows beside it had been correct for months. A formatter outside the layer the tests compile is a
/// formatter nothing checks; that is the reason it moved rather than being patched in place.
func menuBarRate(_ bytesPerSec: Double) -> String {
    // 1000 minus half of the last digit each band prints, per the rule in the file header: 999.5 for
    // the whole-number bands, 999.95 for the one-decimal one. Comparing against a flat 1000 is what
    // let the top of a band round straight past the band it was chosen for.
    let v = max(0, bytesPerSec)
    if v < 999.5 { return String(format: "%.0f B/s", v) }
    let kb = v / 1000
    if kb < 999.5 { return String(format: "%.0f KB/s", kb) }
    let mb = kb / 1000
    if mb < 999.95 { return String(format: "%.1f MB/s", mb) }
    return String(format: "%.1f GB/s", mb / 1000)
}

/// ISO-3166 alpha-2 country code → flag emoji (e.g. "VN" → 🇻🇳) by mapping each letter to its
/// regional-indicator symbol. Returns "" for anything that isn't two letters.
func flagEmoji(_ code: String) -> String {
    let up = code.uppercased()
    guard up.count == 2, up.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "" }
    let base: UInt32 = 0x1F1E6 - 0x41   // regional indicator "A" minus ASCII 'A'
    var s = ""
    for scalar in up.unicodeScalars {
        if let flag = UnicodeScalar(base + scalar.value) { s.unicodeScalars.append(flag) }
    }
    return s
}
