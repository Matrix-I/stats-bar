// UsageHistory.swift — the fixed-length ring of recent readings behind the USAGE HISTORY chart, and
// the arithmetic that turns it into a polyline.
//
// The polyline lives here, not in the view, for the reason the repo's memory bugs were extracted
// into MemoryBuckets: arithmetic inside a SwiftUI body is arithmetic no test can reach, and a chart
// is a shape whose wrongness reads as a design choice. The specific thing worth pinning is that the
// series is anchored to the RIGHT edge. A history that has only been collecting for eight seconds
// must draw eight seconds of line ending at "now" on the right, with the left of the panel empty —
// not eight samples stretched across the full width, which would silently rescale the time axis
// every tick for the first minute after the popover opens and make an idle GPU look like a spiky one.

import Foundation
import CoreGraphics

struct UsageHistory: Equatable {
    /// How many samples are kept. Deliberately a count of SAMPLES and not a duration: the reader
    /// feeding this slows down when nobody has the popover open, so the window is a fixed number of
    /// readings whose spacing varies. That is also why the chart carries no time axis — labelling one
    /// would be claiming a scale this does not have.
    let capacity: Int

    /// Oldest first, newest last. Never longer than `capacity`.
    private(set) var samples: [Double] = []

    /// A non-positive capacity is floored at 1 rather than trusted: it would otherwise make `append`
    /// drop every sample it was just handed, which is a chart that is permanently, silently empty.
    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Records a reading, evicting the oldest once the window is full.
    ///
    /// Non-finite values are dropped instead of stored. There is no sensible y for a NaN, and one
    /// stored sample would poison every frame the chart draws from then until it aged out of the
    /// window — far past the tick that produced it, which is what makes it worth refusing at the door.
    mutating func append(_ value: Double) {
        guard value.isFinite else { return }
        samples.append(value)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    /// The samples as points in a `width` × `height` box, newest at the right edge and y measured
    /// downward (SwiftUI's convention, so the view can stroke the result unmodified).
    ///
    /// The horizontal step is set by `capacity`, NOT by how many samples are held — that is the
    /// right-anchoring described in the header, and it is why a half-full window draws a short line
    /// rather than a stretched one. `maximum` is the top of the y axis: passing the axis in keeps
    /// this usable for a series that isn't a percentage, and a non-positive one has no scale to map
    /// onto, so it yields nothing rather than a divide-by-zero.
    func plotPoints(width: CGFloat, height: CGFloat, maximum: Double = 100) -> [CGPoint] {
        guard maximum > 0, !samples.isEmpty else { return [] }
        // capacity is >= 1 by construction, so this only guards the single-slot window, where there
        // is no spacing to compute and the one sample belongs at the right edge.
        let step = capacity > 1 ? width / CGFloat(capacity - 1) : 0
        let last = samples.count - 1
        return samples.enumerated().map { idx, value in
            let fraction = min(1, max(0, value / maximum))
            return CGPoint(x: width - CGFloat(last - idx) * step,
                           y: height - CGFloat(fraction) * height)
        }
    }
}
