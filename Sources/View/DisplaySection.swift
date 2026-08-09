// DisplaySection.swift — the DISPLAYS block in the Control Center hub: one row per attached screen
// with its resolution, refresh rate and panel size.
//
// A section rather than a sixth StatMetric on purpose. Display layout changes a handful of times a
// day, so a permanent menu-bar glyph would spend its life showing a number nobody is waiting on —
// and the notch already rations menu-bar width. This lives where you go to look things up.

import SwiftUI

struct DisplaySection: View {
    let displays: [DisplayInfo]

    var body: some View {
        if !displays.isEmpty {
            SectionCaption("DISPLAYS")
            VStack(spacing: 8) {
                ForEach(displays) { d in
                    DisplayRow(display: d, showRole: displays.count > 1)
                }
            }
        }
    }
}

private struct DisplayRow: View {
    let display: DisplayInfo
    /// Built-in / Main tags only earn their space once more than one screen is attached.
    let showRole: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(display.name).lineLimit(1).truncationMode(.tail)
                if showRole && display.isMain {
                    Text("MAIN")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ValueText(value: display.resolutionText)
            }
            .font(.system(size: 12))

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.leading, 17)   // clear the icon column so it lines up with the name
            }
        }
    }

    /// The second line: the panel's native grid, refresh rate and diagonal — whichever the display
    /// reports. The headline above is the desktop's point grid, matching System Settings, so this
    /// line is where the physical panel gets named.
    private var caption: String? {
        var parts: [String] = []
        if let native = display.nativeText { parts.append(native) }
        if let hz = display.refreshHz { parts.append("\(roundedInt(hz)) Hz") }
        if let inches = display.diagonalInches { parts.append(String(format: "%.1f\"", inches)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
