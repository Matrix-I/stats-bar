// GPUStatistics.swift — the accelerator's "PerformanceStatistics" dictionary turned into a value
// type, plus the energy-counter-to-watts arithmetic. Both halves are here rather than in GPUReader
// for the reason the memory path exists: a number that is wrong but plausible is invisible in a
// panel, and only a test catches it.
//
// WHAT THE THREE UTILISATION FIGURES ACTUALLY MEAN, because it decides whether showing all three is
// informative or triplicated noise. They are not redundant, and that was measured rather than
// assumed: a Metal COMPUTE kernel pinned "Device Utilization %" at 97 while "Renderer Utilization %"
// and "Tiler Utilization %" both stayed at exactly 0, and a Metal RENDER pass driving the same die
// put all three at 97–98. So Device is the whole GPU's busy share, while Renderer and Tiler are the
// two halves of Apple's tile-based deferred pipeline — geometry/binning and fragment shading — and
// they answer a question Device cannot: whether the load is graphics or compute. On a GPU that is
// not tile-based (an Intel or AMD part) the driver publishes no tiler key at all, which is why every
// field here is optional and the panel renders only what exists.
//
// Absent means nil, never zero. A missing key and an idle GPU are different facts and they format
// identically once a nil has been coerced to 0 — the same trap that printed "Design capacity: 0 mAh"
// on the battery card for a whole release.

import Foundation

struct GPUStatistics: Equatable {
    /// Busy share of the whole device, 0…100 — the headline figure and the one the menu-bar glyph
    /// and the history chart track.
    var deviceUtilization: Double?
    /// Fragment-shading share of the tile-based pipeline. nil on a GPU that isn't tile-based.
    var rendererUtilization: Double?
    /// Geometry/binning share of the tile-based pipeline. nil on a GPU that isn't tile-based.
    var tilerUtilization: Double?

    /// Bytes the driver currently has mapped for this device, and the total it has allocated. On
    /// Apple Silicon these are system RAM (the GPU has no separate pool), so they are reported as
    /// "in use" rather than as a VRAM budget, which would imply a ceiling that does not exist.
    var inUseMemory: UInt64?
    var allocatedMemory: UInt64?

    /// Reads the driver dictionary. Every key is optional and every value is range-checked, because
    /// this is a vendor-supplied dictionary with no contract behind it: the keys differ across Apple,
    /// Intel and AMD drivers, and nothing stops one publishing a percentage outside 0…100.
    static func parse(_ stats: [String: Any]) -> GPUStatistics {
        var out = GPUStatistics()
        out.deviceUtilization = percent(stats["Device Utilization %"])
        out.rendererUtilization = percent(stats["Renderer Utilization %"])
        out.tilerUtilization = percent(stats["Tiler Utilization %"])
        out.inUseMemory = bytes(stats["In use system memory"])
        out.allocatedMemory = bytes(stats["Alloc system memory"])
        return out
    }

    /// A driver-published percentage, or nil when the key is missing or the value cannot be plotted.
    ///
    /// The isFinite guard is not defensive boilerplate. These arrive as NSNumber from a kernel
    /// dictionary, so a NaN is representable, and a NaN reaches SwiftUI's `trim(from:to:)` as a ring
    /// that renders as CoreGraphics errors rather than as anything visible — a failure that looks
    /// like a layout bug and sends you looking in the wrong file. Rejecting it here means the panel
    /// hides the ring, which at least says "no reading".
    ///
    /// Out-of-range values are clamped rather than rejected, which is the opposite call and
    /// deliberate: 100.0000001 from a float conversion is a real reading and dropping it would blank
    /// a working ring, whereas a NaN is not a reading at all.
    private static func percent(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber else { return nil }
        let v = n.doubleValue
        guard v.isFinite else { return nil }
        return min(100, max(0, v))
    }

    private static func bytes(_ any: Any?) -> UInt64? {
        guard let n = any as? NSNumber else { return nil }
        let v = n.int64Value
        return v >= 0 ? UInt64(v) : nil
    }
}

/// The IOReport "GPU Energy" channel, which counts cumulative energy rather than reporting power —
/// so the panel's watts are a quotient this app computes, not a figure the system hands over.
enum GPUEnergy {
    /// Watts from an energy delta and the wall time it accumulated over.
    ///
    /// The channel's unit label reads "nJ", and the load measurements are what make taking it at its
    /// word credible: on this M1 Pro, 24,239,942,710 nJ over 3 s of a saturating Metal compute kernel
    /// is 8.08 W, and a heavy render pass measured 19.3 W. Those are the right order of magnitude for
    /// a 14-core integrated GPU; had the unit been mJ the same counters would read 8 kW and 19 kW,
    /// which is how a mis-scaled quotient announces itself. The idle end is no help in pinning the
    /// scale — an Apple GPU power-gates so completely that consecutive idle seconds measure 0.000000,
    /// 0.000438 and 0.000000 W — but it is worth knowing, because it means a GPU doing nothing
    /// genuinely reports zero watts rather than a floor.
    ///
    /// Both guards reject rather than saturate. A non-positive interval has no quotient at all, and a
    /// negative delta means the counter restarted underneath us (the subscription is re-primed every
    /// time the popover reopens) — returning 0 W for either would be indistinguishable from a real
    /// idle GPU, and holding the previous reading is the caller's decision to make, not this one's.
    static func watts(nanojoules: Int64, seconds: Double) -> Double? {
        guard seconds > 0, nanojoules >= 0 else { return nil }
        return Double(nanojoules) / 1e9 / seconds
    }
}
