// Components.swift — small reusable views shared across the detail panel sections.

import SwiftUI

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
