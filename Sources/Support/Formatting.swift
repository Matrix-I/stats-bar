// Formatting.swift — small presentation helpers shared across the views.

import SwiftUI

func healthColor(_ p: Double) -> Color {
    p >= 80 ? .green : (p >= 60 ? .orange : .red)
}

func fmtMinutes(_ m: Int) -> String { "\(m / 60)h \(String(format: "%02d", m % 60))m" }

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
    return mib >= 1024 ? String(format: "%.2f GB", mib / 1024) : String(format: "%.0f MB", mib)
}

/// Bytes → "55.8 MB" using decimal units (÷1000), matching how macOS reports network data transfer
/// (bytes, KB, MB, GB, TB). Kept separate from fmtGB, which uses binary GiB for RAM.
func fmtBytes(_ bytes: UInt64) -> String {
    let units = ["bytes", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var i = 0
    while value >= 1000 && i < units.count - 1 { value /= 1000; i += 1 }
    // Whole bytes read as integers; everything larger keeps one decimal (like Activity Monitor).
    return i == 0 ? "\(Int(value)) bytes" : String(format: "%.1f %@", value, units[i])
}

/// Bytes-per-second → "1.2 MB/s" for the live throughput rows.
func fmtRate(_ bytesPerSec: Double) -> String {
    fmtBytes(UInt64(max(0, bytesPerSec))) + "/s"
}

/// Splits a bytes/sec rate into a big number and its unit ("2" + "KB/s") for the prominent
/// Download/Upload header. Whole numbers up to KB/s (like the reference design); one decimal for
/// small MB/s+ so a slow megabyte-range link still reads meaningfully.
func fmtRateParts(_ bytesPerSec: Double) -> (value: String, unit: String) {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var value = max(0, bytesPerSec)
    var i = 0
    while value >= 1000 && i < units.count - 1 { value /= 1000; i += 1 }
    let valueStr: String
    switch i {
    case 0, 1: valueStr = String(Int(value.rounded()))                        // B/s, KB/s → whole
    default:   valueStr = value < 10 ? String(format: "%.1f", value)          // small MB/s+ → 1 dp
                                     : String(Int(value.rounded()))
    }
    return (valueStr, units[i])
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
