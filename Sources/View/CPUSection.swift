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

            cores

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
            LegendRow(color: CPUPalette.system, label: "System", value: pct(info.systemPercent))
            LegendRow(color: CPUPalette.user, label: "User", value: pct(info.userPercent))
            LegendRow(color: CPUPalette.idle, label: "Idle", value: pct(info.idlePercent))

            if let eff = info.efficiencyPercent {
                LegendRow(color: CPUPalette.efficiency, label: "Efficiency cores", value: pct(eff))
            }
            if let perf = info.performancePercent {
                LegendRow(color: CPUPalette.performance, label: "Performance cores", value: pct(perf))
            }

            LegendRow(color: thermalColor(info.thermalState), label: "Thermal",
                      value: thermalText(info.thermalState))
            if info.lowPowerMode {
                InfoRow(label: "Low Power Mode", value: "On")
            }
            if info.loadAverage.count == 3 {
                // "/ core" is load-bearing, not decoration: `uptime`, Activity Monitor and every
                // other tool print the RAW load average, so an unqualified "Load avg" here would
                // disagree with all of them by a factor of coreCount and look like a bug.
                InfoRow(label: "Load avg / core (1/5/15m)", value: loadText(info.loadAverage))
            }
            InfoRow(label: "Uptime", value: fmtUptime(info.uptimeSeconds))
        }
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }

    /// Per-core load, so 1.00 means "exactly as much runnable work as this machine has cores".
    private func loadText(_ v: [Double]) -> String {
        v.map { String(format: "%.2f", $0) }.joined(separator: " / ")
    }

    private func thermalText(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:    return "Nominal"
        case .fair:       return "Fair"
        case .serious:    return "Serious"
        case .critical:   return "Critical"
        @unknown default: return "Unknown"
        }
    }

    /// Deliberately a popover row rather than a menu-bar tint: the CPU glyph is rendered as a
    /// template image (see MenuBar.symbolPercentMenuBarImage), which macOS recolours monochrome, so
    /// "turn the glyph orange" would mean abandoning template rendering and folding appearance into
    /// the glyph cache key — a rewrite far out of proportion to the signal.
    private func thermalColor(_ s: ProcessInfo.ThermalState) -> Color {
        switch s {
        case .nominal:    return .green
        case .fair:       return .yellow
        case .serious:    return .orange
        case .critical:   return .red
        @unknown default: return CPUPalette.idle
        }
    }

    // MARK: Cores

    /// One mini-bar per logical core — the view MenuMeters and iStat Menus are known for, and the
    /// only place the load's actual shape is visible: two cluster averages can't tell a single pegged
    /// core apart from every core at a third. The reader already computes this array to derive those
    /// averages, so the section costs no extra sampling. Four columns keeps an 8- or 10-core chip to
    /// two rows; colour carries the cluster (matching the DETAILS rows), so no per-cell label is
    /// needed to tell efficiency from performance.
    ///
    /// The die temperature sits above each bar, pairing zone i with core i. That pairing is a
    /// CONVENTION, not something the SMC states, and on this chip it is provably imperfect: the die
    /// has ten thermal zones and eight live cores (max_cpus=10 with cpu-ids 5 and 9 absent from the
    /// device tree — two fused-off sites), and loading the six performance cores heated zones 0, 1, 3,
    /// 5, 6 and 8, which is neither the contiguous run that core order predicts nor the one that
    /// physical cpu-id order predicts. So a given cell may be showing a sibling core's zone. What
    /// bounds the damage is that the whole signal is small: the six live performance zones sat within
    /// 2.6 °C of each other at idle and 3.1 °C under load, so a mis-paired cell is off by about as
    /// much as the feature's entire range. Displaying nothing would cost more than that.
    @ViewBuilder
    private var cores: some View {
        if !info.perCoreBusy.isEmpty {
            let temps = info.coreTemperaturesC
            SectionCaption("CORES")
            VStack(spacing: 6) {
                LazyVGrid(columns: Array(repeating: GridItem(spacing: 8), count: 4), spacing: 8) {
                    ForEach(Array(info.perCoreBusy.enumerated()), id: \.offset) { idx, busy in
                        VStack(spacing: 3) {
                            if idx < temps.count {
                                Text("\(Int(temps[idx].rounded()))°")
                                    .font(.system(size: 9))
                                    .monospacedDigit()
                                    .foregroundStyle(coreTempColor(temps[idx]))
                            }
                            BarView(pct: busy, color: coreColor(idx))
                            Text("\(Int(busy.rounded()))%")
                                .font(.system(size: 9))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if temps.count > info.perCoreBusy.count {
                    // Say so rather than quietly dropping them: the hottest zone on the die may be one
                    // of the ones with no cell, and that is the number a throttling machine is
                    // throttling on.
                    Text("\(temps.count) die zones · hottest \(Int((temps.max() ?? 0).rounded()))°")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Quiet until it matters. A die at 57 °C is not news, so the per-core figure reads as secondary
    /// text and only takes on the temperature ring's warning colours once the core is genuinely warm.
    private func coreTempColor(_ c: Double) -> Color { c < 75 ? .secondary : tempColor(c) }

    /// Efficiency cores are the low indices, performance cores follow — see CPUReader's header for how
    /// that ordering was confirmed. A chip that reports no cluster split (Intel) gets one flat colour
    /// rather than a misleading teal/purple division.
    private func coreColor(_ idx: Int) -> Color {
        guard info.efficiencyCoreCount > 0, info.performanceCoreCount > 0 else { return CPUPalette.user }
        return idx < info.efficiencyCoreCount ? CPUPalette.efficiency : CPUPalette.performance
    }

    // MARK: Frequency

    @ViewBuilder
    private var frequency: some View {
        // Only render when IOReport gave us a reading (nil on Intel / unsupported macOS).
        if let all = info.allFrequencyMHz {
            SectionCaption("FREQUENCY")
            VStack(spacing: 6) {
                InfoRow(label: "All cores", value: mhz(all))
                if let eff = info.efficiencyFrequencyMHz {
                    LegendRow(color: CPUPalette.efficiency, label: "Efficiency cores", value: mhz(eff))
                }
                if let perf = info.performanceFrequencyMHz {
                    LegendRow(color: CPUPalette.performance, label: "Performance cores", value: mhz(perf))
                }
            }
        }
    }

    private func mhz(_ v: Double) -> String { "\(Int(v.rounded())) MHz" }

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
                ProcessTableHeader()
                ForEach(info.topProcesses) { p in
                    ProcessRow(pid: p.pid, icon: p.icon, name: p.name,
                               value: String(format: "%.1f%%", p.cpuPercent))
                }
            }
        }
    }
}
