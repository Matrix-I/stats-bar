// GPUSection.swift — the GPU menu-bar item's popover: a centred "GPU" title, one ring per
// utilisation figure the driver publishes, a USAGE HISTORY chart of the headline figure, and a
// DETAILS block. Laid out to match the other metric popovers (its own menu-bar item, its own
// window-visibility reporter driving the reader's cadence).
//
// Three rings rather than one because the three figures answer different questions — GPUStatistics'
// header has the compute-versus-render measurement that establishes they are not the same number —
// and each is rendered only when the driver actually published it, so a non-tile-based GPU shows one
// ring instead of two empty ones.
//
// Two figures that a GPU panel is often expected to carry are deliberately ABSENT, because neither
// is obtainable rather than because they were overlooked:
//   • ANE (Neural Engine) utilisation. There is no such counter. The ANE's registry entry publishes
//     its core count and a binary power state and nothing else, and the IOReport "ANE0" energy
//     channel reads a flat 0 on this SoC while the neighbouring "GPU Energy" channel moves — so even
//     an energy proxy is unavailable here, let alone a percentage.
//   • Frames per second. The GPU publishes no frame counter, and the display's refresh rate — which
//     is readable, and is what a "60" in this position would really be — is a property of the panel,
//     not a measure of what the GPU rendered. It is already shown, correctly labelled, in the
//     Control Center's DISPLAYS section.

import SwiftUI
import AppKit

/// Colour key shared by the rings and the DETAIL rows, in the order the pipeline runs.
enum GPUPalette {
    static let device = Color.blue
    static let renderer = Color.indigo
    static let tiler = Color.teal
    static let idle = Color.gray.opacity(0.5)
}

struct GPUDetailView: View {
    @ObservedObject var reader: GPUReader

    private var info: GPUInfo { reader.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GPU")
                .font(.system(size: 19.5, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)

            if info.primary == nil {
                // Said rather than drawn as zeroes. Every Mac has an accelerator, so an empty list
                // means the read failed, and three rings at 0 % would report an idle GPU instead.
                Text("No GPU reported by the IOKit registry.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                rings
                usageHistory
                details
            }

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

    /// The utilisation figures the primary GPU actually published, in pipeline order. Built as a list
    /// so the ring row and the DETAIL rows below agree by construction about which ones exist.
    private var utilisations: [(label: String, value: Double, color: Color)] {
        guard let stats = info.primary?.stats else { return [] }
        var out: [(String, Double, Color)] = []
        if let v = stats.deviceUtilization   { out.append(("Utilization", v, GPUPalette.device)) }
        if let v = stats.rendererUtilization { out.append(("Render", v, GPUPalette.renderer)) }
        if let v = stats.tilerUtilization    { out.append(("Tiler", v, GPUPalette.tiler)) }
        return out
    }

    @ViewBuilder
    private var rings: some View {
        // 72 pt rings at 18 pt spacing fit three across the 272 pt of content this popover has
        // between its padding; two or one simply centre in the same row.
        HStack(spacing: 18) {
            ForEach(utilisations, id: \.label) { u in
                VStack(spacing: 8) {
                    RingGauge(segments: [.init(value: u.value / 100, color: u.color)]) {
                        Text("\(roundedInt(u.value))%")
                            .font(.system(size: 18, weight: .semibold))
                            .monospacedDigit()
                    }
                    .frame(width: 72, height: 72)

                    Text(u.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    // MARK: History

    @ViewBuilder
    private var usageHistory: some View {
        SectionCaption("USAGE HISTORY")
        HistoryChart(history: info.history, color: GPUPalette.device)
    }

    // MARK: Details

    @ViewBuilder
    private var details: some View {
        SectionCaption("DETAILS")
        VStack(spacing: 6) {
            if let gpu = info.primary {
                InfoRow(label: "Model", value: gpu.name)
                if let cores = gpu.coreCount {
                    InfoRow(label: "Cores", value: "\(cores)")
                }
            }

            ForEach(utilisations, id: \.label) { u in
                LegendRow(color: u.color, label: u.label == "Utilization" ? u.label : "\(u.label) utilization",
                          value: "\(roundedInt(u.value))%")
            }

            if let w = info.powerWatts {
                // Two decimals for the low single digits — a lightly loaded GPU sits there, and
                // whole watts would round most of that band to the same number. It is NOT to save the
                // idle reading: an Apple GPU power-gates to a measured 0.0004 W, so "0.00 W" is the
                // honest rendering of an idle GPU rather than a rounding casualty.
                InfoRow(label: "Power", value: String(format: "%.2f W", w))
            }

            if let stats = info.primary?.stats {
                if let used = stats.inUseMemory {
                    InfoRow(label: "Memory in use", value: fmtBytes(used))
                }
                if let alloc = stats.allocatedMemory {
                    // "Allocated" and not "Total" or "VRAM": on Apple Silicon this is system RAM the
                    // driver has taken, not a dedicated pool, so naming it as a capacity would invent
                    // a ceiling the hardware does not have.
                    InfoRow(label: "Memory allocated", value: fmtBytes(alloc))
                }
            }

            // A second accelerator is real on the dual-GPU Intel Macs. The rings above describe the
            // first one; the rest get a row each rather than being dropped, because "which GPU is
            // this reading from" is otherwise unanswerable from the panel.
            ForEach(info.devices.dropFirst()) { other in
                InfoRow(label: other.name,
                        value: other.stats.deviceUtilization.map { "\(roundedInt($0))%" } ?? "—")
            }
        }
    }
}
