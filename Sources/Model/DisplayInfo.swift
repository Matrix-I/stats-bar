// DisplayInfo.swift — one attached display, as CoreGraphics and NSScreen describe it. Populated by
// DisplayReader; rendered by DisplaySection inside the Control Center hub.

import Foundation
import CoreGraphics

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let name: String

    /// The logical grid the desktop is laid out in — what System Settings shows as the "looks like"
    /// resolution. This is the headline figure because it is the only one that also appears in
    /// macOS's own UI, so the two agree instead of quietly contradicting each other.
    let pointWidth: Int
    let pointHeight: Int

    /// The panel's true pixel grid, from the largest 1:1 mode it advertises (see DisplayReader).
    /// nil when the mode list can't be read.
    let nativeWidth: Int?
    let nativeHeight: Int?

    let refreshHz: Double?
    let scale: Double
    let isBuiltIn: Bool
    let isMain: Bool
    /// Physical panel size in millimetres, when the display reports it (EDID). nil otherwise.
    let physicalMM: CGSize?

    var resolutionText: String { "\(pointWidth) × \(pointHeight)" }

    /// The panel grid, shown only where it differs from the desktop grid — on a 1× external display
    /// the two are identical and printing the same numbers twice is noise.
    var nativeText: String? {
        guard let w = nativeWidth, let h = nativeHeight,
              w != pointWidth || h != pointHeight else { return nil }
        return "\(w) × \(h) native"
    }

    /// Panel diagonal in inches, derived from the EDID millimetre size. nil when unreported — and
    /// deliberately not guessed from resolution, which cannot distinguish a 24" from a 27" 1080p.
    var diagonalInches: Double? {
        guard let mm = physicalMM, mm.width > 0, mm.height > 0 else { return nil }
        return (mm.width * mm.width + mm.height * mm.height).squareRoot() / 25.4
    }
}
