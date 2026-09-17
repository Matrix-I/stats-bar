// UsageHistoryTests.swift — the ring buffer behind the USAGE HISTORY chart and the polyline it
// produces.
//
// The reason the geometry is tested at all is that a chart cannot be read for correctness. A line
// that is subtly wrong still looks like a line, and the specific wrongness this guards against —
// stretching a partly-filled window across the full panel — is not even ugly: it produces a
// confident, smooth, completely fictional trace during exactly the first minute after launch, which
// is when most people look at it. Nothing but an assertion on the x coordinates catches that.

import Testing
import CoreGraphics
@testable import StatsBarCore

@Suite("Usage history")
struct UsageHistoryTests {

    private func history(capacity: Int, _ values: [Double]) -> UsageHistory {
        var h = UsageHistory(capacity: capacity)
        for v in values { h.append(v) }
        return h
    }

    // MARK: The ring

    @Test("The window keeps the newest samples and evicts the oldest")
    func windowEvictsOldest() {
        let h = history(capacity: 3, [1, 2, 3, 4, 5])
        #expect(h.samples == [3, 4, 5])
    }

    @Test("A window that is not yet full keeps everything, oldest first")
    func partialWindowKeepsOrder() {
        #expect(history(capacity: 60, [10, 20, 30]).samples == [10, 20, 30])
    }

    @Test("A non-positive capacity is floored rather than obeyed")
    func nonPositiveCapacityIsFloored() {
        // Obeying a capacity of 0 means every append immediately evicts what it just stored, which is
        // a chart that is permanently empty with no error anywhere to say why.
        var h = UsageHistory(capacity: 0)
        h.append(42)
        #expect(h.capacity == 1)
        #expect(h.samples == [42])
    }

    @Test("A non-finite sample is refused at the door")
    func nonFiniteSamplesAreDropped() {
        // Storing one would break every frame drawn until it aged out of the window — long after the
        // tick that produced it, so the symptom would appear unrelated to its cause.
        let h = history(capacity: 10, [1, .nan, 2, .infinity, 3, -.infinity])
        #expect(h.samples == [1, 2, 3])
    }

    // MARK: The polyline

    @Test("A half-full window draws against the right edge instead of stretching")
    func partialWindowIsRightAnchored() {
        // THE case this file exists for. Three samples in a sixty-wide window at 600 pt: the step is
        // set by the capacity (600/59), so the trace occupies the last two steps and the left of the
        // panel stays empty. Were the step set by `samples.count` instead, these would land on 0, 300
        // and 600 — a full-width trace whose time axis silently rescales on every tick.
        let points = history(capacity: 60, [10, 20, 30])
            .plotPoints(width: 590, height: 100, maximum: 100)
        #expect(points.count == 3)
        #expect(abs(points[0].x - 570) < 1e-9)
        #expect(abs(points[1].x - 580) < 1e-9)
        #expect(abs(points[2].x - 590) < 1e-9)
    }

    @Test("The newest sample always sits exactly on the right edge")
    func newestIsOnTheRightEdge() {
        for count in 1...5 {
            let points = history(capacity: 10, Array(repeating: 50, count: count))
                .plotPoints(width: 90, height: 40)
            #expect(points.last?.x == 90)
        }
    }

    @Test("A full window spans the whole width")
    func fullWindowSpansTheWidth() {
        let points = history(capacity: 5, [1, 2, 3, 4, 5]).plotPoints(width: 80, height: 40)
        #expect(points.first?.x == 0)
        #expect(points.last?.x == 80)
    }

    @Test("Values map to y inverted, because SwiftUI measures downward")
    func valuesMapToInvertedY() {
        let points = history(capacity: 3, [0, 50, 100]).plotPoints(width: 20, height: 40, maximum: 100)
        #expect(points[0].y == 40)   // 0 % sits on the floor
        #expect(points[1].y == 20)
        #expect(points[2].y == 0)    // 100 % touches the ceiling
    }

    @Test("A reading above the axis is clamped to it rather than drawn outside the plate")
    func aboveAxisIsClamped() {
        let points = history(capacity: 2, [250]).plotPoints(width: 10, height: 40, maximum: 100)
        #expect(points[0].y == 0)
    }

    @Test("A custom axis rescales the series")
    func customMaximumRescales() {
        // The axis is a parameter so a future non-percentage series need not pre-scale itself.
        let points = history(capacity: 2, [5]).plotPoints(width: 10, height: 40, maximum: 10)
        #expect(points[0].y == 20)
    }

    @Test("An axis of zero yields nothing rather than dividing by it")
    func nonPositiveMaximumYieldsNothing() {
        #expect(history(capacity: 3, [1, 2]).plotPoints(width: 10, height: 10, maximum: 0).isEmpty)
        #expect(history(capacity: 3, [1, 2]).plotPoints(width: 10, height: 10, maximum: -5).isEmpty)
    }

    @Test("An empty history yields no points, so the chart draws its plate alone")
    func emptyHistoryYieldsNothing() {
        #expect(UsageHistory(capacity: 60).plotPoints(width: 100, height: 40).isEmpty)
    }

    @Test("A single-slot window puts its one sample on the right edge with no spacing to compute")
    func singleSlotWindow() {
        let points = history(capacity: 1, [75]).plotPoints(width: 100, height: 40)
        #expect(points.count == 1)
        #expect(points[0].x == 100)
        #expect(points[0].y == 10)
    }

    @Test("A zero-width box collapses every point onto the same x without misbehaving")
    func zeroWidthIsHarmless() {
        // GeometryReader hands out a zero size for a frame before layout settles, so this runs for
        // real on the first pass rather than being a hypothetical.
        let points = history(capacity: 4, [10, 20]).plotPoints(width: 0, height: 0)
        #expect(points.count == 2)
        #expect(points.allSatisfy { $0.x == 0 && $0.y == 0 })
    }
}
