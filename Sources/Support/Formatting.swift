// Formatting.swift — small presentation helpers shared across the views.

import SwiftUI

func healthColor(_ p: Double) -> Color {
    p >= 80 ? .green : (p >= 60 ? .orange : .red)
}

func fmtMinutes(_ m: Int) -> String { "\(m / 60)h \(String(format: "%02d", m % 60))m" }

/// Bytes → "x.xx GB" using binary GiB (÷1024³), matching how macOS labels RAM (a 16 GiB Mac reads "16.00 GB").
func fmtGB(_ bytes: UInt64) -> String {
    String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
}
