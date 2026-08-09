// BatteryHealthFiguresTests.swift — pins the one thing this type decides: whether the small ratio
// under "Maximum Capacity" is a second source or the headline restated.
//
// The failure it guards is not a wrong number, which is what makes it worth a test file. Both cards
// render perfectly plausibly with the bug present — a headline and a corroborating caption, both
// correct arithmetic — and the only way to tell is to know that the two came from the same division.
// Nothing in a screenshot, and nothing in a review of either property alone, distinguishes them.

import Testing
@testable import StatsBarCore

@Suite("Battery health figures")
struct BatteryHealthFiguresTests {

    // MARK: percent — present is not the same question as usable

    @Test("percent needs both figures strictly positive", arguments: [
        (Int?.none, Int?.some(6075)),
        (Int?.some(5047), Int?.none),
        (Int?.some(0), Int?.some(6075)),      // the iPhone case: iOS publishes 0 rather than omitting
        (Int?.some(5047), Int?.some(0)),
        (Int?.some(-1), Int?.some(6075)),
        (Int?.some(5047), Int?.some(-1)),
    ])
    func percentRejectsUnusableInput(numerator: Int?, denominator: Int?) {
        #expect(BatteryHealthFigures.percent(numerator, of: denominator) == nil)
    }

    @Test("percent is numerator over denominator as a percentage")
    func percentComputesTheRatio() {
        // This Mac's own pack, so the expected figure is checkable against the card on screen.
        let pct = BatteryHealthFigures.percent(5047, of: 6075)
        #expect(pct != nil)
        #expect(abs((pct ?? 0) - 83.078) < 0.001)
    }

    // MARK: the decision

    @Test("two independent figures are both shown")
    func bothFiguresSurviveWhenTheyAreIndependent() {
        // The ordinary, correct state: iOS reported a nominal capacity, so the headline comes from it
        // and the raw ratio underneath genuinely is a different measurement.
        let f = BatteryHealthFigures(preferred: 89.4, raw: 83.1)
        #expect(f.maximumCapacity == 89.4)
        #expect(f.raw == 83.1)
    }

    @Test("the raw ratio is suppressed once it becomes the headline")
    func fallbackLeavesNothingToPrintUnderneath() {
        // The Mac's state on every launch until system_profiler answers, and the iPhone's whenever
        // NominalChargeCapacity is absent or zero. The headline is the raw ratio, so a caption
        // printing the raw ratio is the same number claiming to be a second opinion.
        let f = BatteryHealthFigures(preferred: nil, raw: 83.1)
        #expect(f.maximumCapacity == 83.1)
        #expect(f.raw == nil)
    }

    @Test("an OS figure that happens to equal the raw ratio is not printed twice")
    func identicalFiguresCollapse() {
        // Not the fallback path — this one has an OS figure — but the printed result would be
        // indistinguishable from it, so it is suppressed on the same grounds.
        let f = BatteryHealthFigures(preferred: 83.1, raw: 83.1)
        #expect(f.maximumCapacity == 83.1)
        #expect(f.raw == nil)
    }

    @Test("figures a hair apart are both kept")
    func nearlyEqualFiguresAreBothKept() {
        // The guard must be exact equality, not a tolerance. Two sources landing within a tenth of a
        // point of each other is the most informative pair the card can show — agreement — and an
        // epsilon would be precisely the rule that hid it.
        let f = BatteryHealthFigures(preferred: 83.1, raw: 83.2)
        #expect(f.raw == 83.2)
    }

    @Test("with neither source there is nothing to show")
    func noSourcesYieldNothing() {
        // A device that published no capacities at all: the card must hide the whole block rather
        // than print a zero, which would read as a dead battery.
        let f = BatteryHealthFigures(preferred: nil, raw: nil)
        #expect(f.maximumCapacity == nil)
        #expect(f.raw == nil)
    }
}
