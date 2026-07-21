// CPUSection.swift — the CPU menu-bar item's popover: a centred "CPU" title, two rings (live
// usage on the left, die temperature on the right), and a DETAILS block breaking the load into
// System / User / Idle plus the efficiency- and performance-core averages and uptime. Laid out to
// mirror the reference design (Stats' CPU tab) but pared down per the brief: no corner icons, two
// rings instead of three, and no usage-history graph.
//
// Its own menu-bar item and popover (like Network), so it never shares space with the battery
// panel. The window-visibility reporter tells CPUReader when to switch to its 1 Hz "live" cadence
// and read temperature; the lighter load sample keeps running while closed so the menu-bar
// percentage stays current.

import SwiftUI
import AppKit

/// Colour key shared by the usage ring's two arcs and the DETAIL rows, matching the reference.
enum CPUPalette {
    static let system = Color.red
    static let user = Color.blue
    static let idle = Color.gray.opacity(0.5)
    static let efficiency = Color.teal
    static let performance = Color.purple
}

struct CPUDetailView: View {
    @ObservedObject var reader: CPUReader

    private var info: CPUInfo { reader.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CPU")
                .font(.system(size: 19.5, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)

            rings

            details

            frequency

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
            if let subtitle = chipSubtitle {
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 28) {
                usageRing
                temperatureRing
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
    }

    /// The chip identity shown above the rings — its marketing name plus the core split, e.g.
    /// "Apple M1 Pro (2E/6P)". The (…E/…P) suffix only appears on chips that report both cluster
    /// counts (Apple Silicon); an Intel Mac shows just the brand string.
    private var chipSubtitle: String? {
        guard let name = info.chipName, !name.isEmpty else { return nil }
        let e = info.efficiencyCoreCount, p = info.performanceCoreCount
        return (e > 0 && p > 0) ? "\(name) (\(e)E/\(p)P)" : name
    }

    private var usageRing: some View {
        VStack(spacing: 8) {
            RingGauge(segments: [
                .init(value: info.systemPercent / 100, color: CPUPalette.system),
                .init(value: info.userPercent / 100, color: CPUPalette.user),
            ]) {
                Text("\(Int(info.usagePercent.rounded()))%")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: 86, height: 86)

            Text("Usage").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        }
    }

    private var temperatureRing: some View {
        VStack(spacing: 8) {
            RingGauge(segments: [
                .init(value: (info.temperatureC ?? 0) / 100, color: tempColor(info.temperatureC)),
            ]) {
                Group {
                    if let t = info.temperatureC {
                        Text("\(Int(t.rounded()))°")
                            .font(.system(size: 22, weight: .semibold))
                            .monospacedDigit()
                    } else {
                        Text("—").font(.system(size: 22, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 86, height: 86)

            Text("Temperature").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        }
    }

    private func tempColor(_ c: Double?) -> Color {
        guard let c else { return CPUPalette.idle }
        // Apple-Silicon performance-core die runs hot: idle ~45–55 °C, sustained load ~85–95 °C.
        return c < 75 ? .green : (c < 90 ? .orange : .red)
    }

    // MARK: Details

    @ViewBuilder
    private var details: some View {
        SectionCaption("DETAILS")
        VStack(spacing: 6) {
            CPUStatRow(color: CPUPalette.system, label: "System", value: pct(info.systemPercent))
            CPUStatRow(color: CPUPalette.user, label: "User", value: pct(info.userPercent))
            CPUStatRow(color: CPUPalette.idle, label: "Idle", value: pct(info.idlePercent))

            if let eff = info.efficiencyPercent {
                CPUStatRow(color: CPUPalette.efficiency, label: "Efficiency cores", value: pct(eff))
            }
            if let perf = info.performancePercent {
                CPUStatRow(color: CPUPalette.performance, label: "Performance cores", value: pct(perf))
            }

            InfoRow(label: "Uptime", value: fmtUptime(info.uptimeSeconds))
        }
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }

    // MARK: Frequency

    @ViewBuilder
    private var frequency: some View {
        // Only render when IOReport gave us a reading (nil on Intel / unsupported macOS).
        if let all = info.allFrequencyMHz {
            SectionCaption("FREQUENCY")
            VStack(spacing: 6) {
                InfoRow(label: "All cores", value: mhz(all))
                if let eff = info.efficiencyFrequencyMHz {
                    CPUStatRow(color: CPUPalette.efficiency, label: "Efficiency cores", value: mhz(eff))
                }
                if let perf = info.performanceFrequencyMHz {
                    CPUStatRow(color: CPUPalette.performance, label: "Performance cores", value: mhz(perf))
                }
            }
        }
    }

    private func mhz(_ v: Double) -> String { "\(Int(v.rounded())) MHz" }

    // MARK: Top processes

    private var iconSize: CGFloat { 16 }

    /// The process's app icon, or a generic placeholder glyph for daemons/helpers that have none.
    @ViewBuilder
    private func processIcon(_ icon: NSImage?) -> some View {
        if let icon {
            Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "gearshape.fill")
                .resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
                .padding(1)
        }
    }

    @ViewBuilder
    private var topProcesses: some View {
        SectionCaption("TOP PROCESSES")
        if info.topProcesses.isEmpty {
            Text("Reading…")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                HStack {
                    Text("Process")
                    Spacer()
                    Text("Usage")
                }
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, iconSize + 8)   // align the header with the names, past the icons

                ForEach(info.topProcesses) { p in
                    HStack(spacing: 8) {
                        processIcon(p.icon).frame(width: iconSize, height: iconSize)
                        Text(p.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(String(format: "%.1f%%", p.cpuPercent))
                            .fontWeight(.medium).monospacedDigit()
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }
}

/// A DETAIL row: a colour-keyed square (tying it to the ring), the label in white, and the value.
/// Mirrors the Memory legend rows so the two popovers read identically.
private struct CPUStatRow: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 2).fill(color)
                .frame(width: 9, height: 9)
            Text(label).foregroundStyle(.white)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 12))
    }
}
