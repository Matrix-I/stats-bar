// BatteryHealthFigures.swift — which battery-health percentages a card may show at once, and when
// the small one underneath is only the headline again.
//
// Both battery cards show the same pair: a headline "Maximum Capacity", and beneath it, in caption
// type, the raw full-charge-vs-design ratio. Showing both is worth the pixels precisely because they
// come from different places — the headline is the smoothed figure the OS itself publishes (macOS
// through system_profiler, iOS through NominalChargeCapacity), while the caption is arithmetic on two
// mAh numbers printed right beside it, which anyone can check. A reader who sees both is being shown
// a claim and an independent corroboration of it.
//
// What this type exists to prevent is showing that pair when there is only one figure. Each card
// derives its headline with a FALLBACK to the raw ratio, for when the OS figure is missing — and each
// then printed the caption on a test that did not notice the fallback had been taken. The Mac's
// caption was unconditional. The iPhone's tested `nominalChargeCapacity != nil` while the headline
// tested `nominal > 0`, so a device publishing a zero there satisfied one and not the other. Either
// way the same division prints twice, once rounded to a whole percent and once to a tenth, and reads
// as two sources that agree. That is worse than showing one number: the second one is evidence, and
// it is fabricated.
//
// The Mac case is not exotic. Its headline falls back for as long as it takes system_profiler to
// answer — every launch — and for good on a machine where that read fails.
//
// It lives here rather than in the two models because a decision about what NOT to draw is invisible
// in a screenshot: both spellings render a card that looks entirely reasonable, and only knowing
// where the numbers came from tells them apart. Sources/Model cannot be reached by a test.

import Foundation

struct BatteryHealthFigures: Equatable {
    /// The percentage the card shows big, or nil when neither source could produce one.
    var maximumCapacity: Double?

    /// The raw ratio to show underneath, or nil when it would restate `maximumCapacity` rather than
    /// corroborate it. A view should show its caption if and only if this is non-nil.
    var raw: Double?

    /// - Parameters:
    ///   - preferred: the smoothed health figure the OS published, when it published one.
    ///   - rawRatio: full-charge over design capacity, as a percentage.
    init(preferred: Double?, raw rawRatio: Double?) {
        guard let preferred else {
            // No OS figure: the raw ratio is promoted to being the headline, so there is nothing left
            // to put underneath it. This is the fallback both cards already took; all that changes is
            // that the caption now knows it happened.
            maximumCapacity = rawRatio
            raw = nil
            return
        }
        maximumCapacity = preferred
        // Exact equality, deliberately, not an epsilon. When these two are the same figure they are
        // the same Double — the same division of the same two integers — so nothing is lost to
        // floating-point slack. An epsilon would additionally suppress two genuinely independent
        // readings that happened to land a hair apart, and that is the one pair most worth seeing:
        // agreement between separate sources is the whole reason to print both.
        raw = rawRatio == preferred ? nil : rawRatio
    }

    /// mAh over mAh as a percentage, or nil when either side is missing or unusable.
    ///
    /// Both figures must be strictly positive. A zero numerator is the case that produced the iPhone
    /// bug: iOS publishes NominalChargeCapacity as 0 on some devices rather than omitting the key, so
    /// "present" and "usable" are different questions and only one of them was being asked.
    static func percent(_ numerator: Int?, of denominator: Int?) -> Double? {
        guard let numerator, numerator > 0, let denominator, denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator) * 100
    }
}
