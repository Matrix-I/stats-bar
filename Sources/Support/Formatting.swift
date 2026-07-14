// Formatting.swift — small presentation helpers shared across the views.

import SwiftUI

func healthColor(_ p: Double) -> Color {
    p >= 80 ? .green : (p >= 60 ? .orange : .red)
}

func fmtMinutes(_ m: Int) -> String { "\(m / 60)h \(String(format: "%02d", m % 60))m" }
