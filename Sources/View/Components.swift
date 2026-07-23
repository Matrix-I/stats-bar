// Components.swift — small reusable views shared across the detail panel sections.

import SwiftUI
import AppKit

struct BarView: View {
    let pct: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(4, geo.size.width * min(max(pct, 0), 100) / 100))
            }
        }
        .frame(height: 8)
    }
}

/// A centred small-caps caption sitting *on* a hairline separator (the "INTERFACE" / "ADDRESS"
/// look), used to title a section. An optional trailing control (e.g. a show-more toggle) is
/// overlaid at the right end of the same line. Shared by the Battery and Network popovers so their
/// section headers match.
struct SectionCaption<Trailing: View>: View {
    private let text: String
    private let trailing: Trailing

    init(_ text: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                hairline
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                    .fixedSize()
                hairline
            }
            HStack { Spacer(); trailing }
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
    }
}

/// A circular gauge: a faint full-circle track with one or more coloured arcs starting at 12
/// o'clock and running clockwise, plus arbitrary centre content. The CPU panel uses it for the
/// temperature ring (one arc) and the usage ring (a red System arc followed by a blue User arc,
/// tying the ring to the coloured DETAIL rows below). Segment values are fractions of the full
/// circle (0…1) and are laid down cumulatively.
struct RingGauge<Center: View>: View {
    struct Segment { let value: Double; let color: Color }

    let segments: [Segment]
    let lineWidth: CGFloat
    private let center: Center

    init(segments: [Segment], lineWidth: CGFloat = 8, @ViewBuilder center: () -> Center) {
        self.segments = segments
        self.lineWidth = lineWidth
        self.center = center()
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)

            // Cumulative start offset per segment; the last arc gets a round cap so the leading
            // edge reads as a clean tip (interior joins stay butt so stacked arcs meet flush).
            let clamped = segments.map { max(0, $0.value) }
            let starts = clamped.reduce(into: [0.0]) { acc, v in acc.append((acc.last ?? 0) + v) }
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                let start = min(1, starts[idx])
                let end = min(1, starts[idx] + max(0, seg.value))
                if end > start {
                    Circle()
                        .trim(from: start, to: end)
                        .stroke(seg.color,
                                style: StrokeStyle(lineWidth: lineWidth,
                                                   lineCap: idx == segments.count - 1 ? .round : .butt))
                        .rotationEffect(.degrees(-90))
                }
            }

            center
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

/// A colour-keyed legend row: a small rounded square tying the row to its chart segment, the label in
/// white, and a right-aligned value. Shared by the CPU DETAIL rows and the Memory legend so the two
/// popovers read identically — it was copy-pasted as CPUStatRow / MemoryLegendRow before.
struct LegendRow: View {
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

// MARK: - TOP PROCESSES table (shared by the CPU and RAM popovers)

/// A process's app icon, or a generic placeholder glyph for the daemons/helpers that own none.
struct ProcessIcon: View {
    let icon: NSImage?

    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "gearshape.fill")
                .resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
                .padding(1)
        }
    }
}

/// One row of a TOP PROCESSES table: the app icon, the (truncating) process name, and a
/// right-aligned value — a CPU % on the CPU tab, a memory size on the RAM tab.
struct ProcessRow: View {
    let icon: NSImage?
    let name: String
    let value: String

    static let iconSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 8) {
            ProcessIcon(icon: icon).frame(width: Self.iconSize, height: Self.iconSize)
            Text(name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

/// The "Process / Usage" header above a TOP PROCESSES table, indented so the labels line up past
/// the icon column.
struct ProcessTableHeader: View {
    var valueLabel: String = "Usage"

    var body: some View {
        HStack {
            Text("Process")
            Spacer()
            Text(valueLabel)
        }
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
        .padding(.leading, ProcessRow.iconSize + 8)   // align the header with the names, past the icons
    }
}
