// MacMemorySection.swift — the live RAM readout in the popover: a "Used" headline, a segmented
// App/Wired/Compressed/Free bar, a colour-keyed legend, and swap. Sits directly below the Fans
// section. Colours mirror Activity Monitor's memory breakdown. The App/Wired/Compressed/Free/Swap
// breakdown collapses behind a show-more toggle (like the battery + power sections) so the popover
// stays short by default; the Used total + bar always show.

import SwiftUI

struct MacMemorySection: View {
    let mem: MemoryInfo
    @AppStorage("showMacMemoryDetails") private var showDetails = false

    // Category palette (also used by the bar segments). `.primary` for App keeps it legible in
    // both light and dark popovers; the rest match Activity Monitor's orange / yellow.
    static let appColor        = Color.primary
    static let wiredColor      = Color.orange
    static let compressedColor = Color.yellow
    static let freeColor       = Color.gray.opacity(0.45)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("🧠 Memory (live)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(showDetails ? Color.white : Color.secondary)
                        .padding(4)
                        .background(
                            Circle().fill(showDetails ? Color.accentColor : Color.secondary.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                .help(showDetails ? "Show less" : "Show more")
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Used").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(fmtGB(mem.used))
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
            }

            MemoryBar(mem: mem)

            if showDetails {
                VStack(spacing: 6) {
                    MemoryLegendRow(color: Self.appColor, label: "App", value: fmtGB(mem.app))
                    MemoryLegendRow(color: Self.wiredColor, label: "Wired", value: fmtGB(mem.wired))
                    MemoryLegendRow(color: Self.compressedColor, label: "Compressed", value: fmtGB(mem.compressed))
                    MemoryLegendRow(color: Self.freeColor, label: "Free", value: fmtGB(mem.free))
                    InfoRow(label: "Swap", value: fmtGB(mem.swapUsed))
                }
            }
        }
    }
}

/// The proportional App | Wired | Compressed | Free bar. The whole track is painted the Free
/// colour, then the three "used" segments overlay from the left — so sub-pixel rounding never
/// leaves a transparent gap at the right edge.
private struct MemoryBar: View {
    let mem: MemoryInfo

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            // Clamp the three "used" segments cumulatively so they can never exceed the track: if
            // the fractions ever sum past 1 (a wired page double-counted in App, or a non-atomic
            // read), the last segment would otherwise spill past the edge and get silently clipped.
            let appW  = min(w * mem.appFraction, w)
            let wiredW = min(w * mem.wiredFraction, w - appW)
            let compW  = min(w * mem.compressedFraction, w - appW - wiredW)
            ZStack(alignment: .leading) {
                Rectangle().fill(MacMemorySection.freeColor)
                HStack(spacing: 0) {
                    Rectangle().fill(MacMemorySection.appColor).frame(width: appW)
                    Rectangle().fill(MacMemorySection.wiredColor).frame(width: wiredW)
                    Rectangle().fill(MacMemorySection.compressedColor).frame(width: compW)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct MemoryLegendRow: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 2).fill(color)
                .frame(width: 9, height: 9)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 12))
    }
}
