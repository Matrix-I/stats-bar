// MemorySection.swift — the Memory menu-bar item's popover: a centred "RAM" title, the total
// installed RAM, two rings (memory pressure on the left, usage % on the right — laid out to mirror
// the CPU tab), then a DETAILS block with the Used total, the proportional App / Wired / Compressed
// / Free bar + legend, and swap. Colours mirror Activity Monitor's memory breakdown.
//
// Its own menu-bar item and popover (like CPU / Network / Bluetooth), so it never shares space with
// the battery panel. It used to be a section INSIDE the battery popover, which made that panel long
// and mixed two unrelated readouts — this is the "move it out of Battery" split. The
// window-visibility reporter tells MemoryReader when to poll at its faster "live" cadence; the
// lighter sample keeps running while closed so the menu-bar percentage stays current.

import SwiftUI
import AppKit

struct MemoryDetailView: View {
    @ObservedObject var reader: MemoryReader

    private var info: MemoryInfo { reader.info }

    // Category palette (also used by the bar segments). `.primary` for App keeps it legible in both
    // light and dark popovers; the rest match Activity Monitor's orange / yellow.
    static let appColor        = Color.primary
    static let wiredColor      = Color.orange
    static let compressedColor = Color.yellow
    static let freeColor       = Color.gray.opacity(0.45)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("RAM")
                .font(.system(size: 19.5, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)

            rings

            details

            topProcesses

            Divider()

            HStack {
                Button("Refresh") { reader.refresh() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowVisibilityReporter(onChange: { reader.setPanelOpen($0) }))
    }

    // MARK: Rings

    @ViewBuilder
    private var rings: some View {
        VStack(spacing: 6) {
            if info.total > 0 {
                Text(totalText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 28) {
                pressureRing
                usageRing
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
    }

    /// Total installed RAM shown above the rings, e.g. "16 GB" — macOS ships exact power-of-two-GiB
    /// modules, so the rounded whole number is accurate. The analog of the CPU tab's chip subtitle.
    private var totalText: String {
        String(format: "%.0f GB", Double(info.total) / 1_073_741_824)
    }

    /// Memory pressure — the arc fills to the non-reclaimable share (wired + compressed), coloured
    /// and captioned by the authoritative kernel level, so a healthy machine reads a modest green
    /// arc labelled "Normal" and the ring turns orange/red under real pressure.
    private var pressureRing: some View {
        VStack(spacing: 8) {
            RingGauge(segments: [
                .init(value: info.pressureFraction, color: pressureColor(info.pressure)),
            ]) {
                Text(info.pressure.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(pressureColor(info.pressure))
            }
            .frame(width: 86, height: 86)

            Text("Pressure").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        }
    }

    private var usageRing: some View {
        VStack(spacing: 8) {
            RingGauge(segments: [
                .init(value: info.usedFraction, color: usageColor(info.usagePercent)),
            ]) {
                Text("\(Int(info.usagePercent.rounded()))%")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: 86, height: 86)

            Text("Usage").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        }
    }

    private func pressureColor(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal:   return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    private func usageColor(_ pct: Double) -> Color {
        pct < 70 ? .green : (pct < 85 ? .orange : .red)
    }

    // MARK: Details

    @ViewBuilder
    private var details: some View {
        // Used total + the proportional App | Wired | Compressed | Free bar.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Used").font(.system(size: 14)).foregroundStyle(.white)
                Spacer()
                Text(fmtGB(info.used))
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
            }
            MemoryBar(mem: info)
        }

        SectionCaption("DETAILS")
        VStack(spacing: 6) {
            LegendRow(color: Self.appColor, label: "App", value: fmtGB(info.app))
            LegendRow(color: Self.wiredColor, label: "Wired", value: fmtGB(info.wired))
            LegendRow(color: Self.compressedColor, label: "Compressed", value: fmtGB(info.compressed))
            LegendRow(color: Self.freeColor, label: "Free", value: fmtGB(info.free))
            InfoRow(label: "Swap", value: fmtGB(info.swapUsed))
        }
    }

    // MARK: Top processes

    @ViewBuilder
    private var topProcesses: some View {
        SectionCaption("TOP PROCESSES")
        if info.topProcesses.isEmpty {
            Text("Reading…")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                ProcessTableHeader(valueLabel: "Memory")
                ForEach(info.topProcesses) { p in
                    ProcessRow(icon: p.icon, name: p.name, value: fmtProcessMemory(p.bytes))
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
                Rectangle().fill(MemoryDetailView.freeColor)
                HStack(spacing: 0) {
                    Rectangle().fill(MemoryDetailView.appColor).frame(width: appW)
                    Rectangle().fill(MemoryDetailView.wiredColor).frame(width: wiredW)
                    Rectangle().fill(MemoryDetailView.compressedColor).frame(width: compW)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
