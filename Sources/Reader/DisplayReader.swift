// DisplayReader.swift — the attached displays, read from NSScreen + CoreGraphics. No polling: macOS
// posts didChangeScreenParameters whenever a display is plugged, unplugged, rearranged or has its
// mode changed, which is every event this data can have. That makes it the cheapest reader in the
// app — it costs nothing at all while the desk is unchanged.
//
// NSScreen is the entry point rather than CGGetActiveDisplayList because only NSScreen carries
// localizedName ("LG FHD") and backingScaleFactor; the CGDirectDisplayID it hands back through
// deviceDescription is then the key to the CoreGraphics half.
//
// Two values are deliberately NOT surfaced, both verified misleading on this hardware:
//   • CGDisplaySerialNumber returns 0x01010101 for the external panel here — a placeholder, not a
//     serial, and showing it would invent an identifier that does not exist.
//   • NSScreen.maximumExtendedDynamicRangeColorComponentValue reads 1.0 even on the built-in XDR
//     panel, because it reports the CURRENT EDR headroom rather than the display's capability. An
//     "HDR" badge driven off it would be wrong on exactly the machines that do support HDR.

import AppKit
import Combine
import CoreGraphics

@MainActor
final class DisplayReader: ObservableObject {
    @Published var displays: [DisplayInfo] = []

    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        displays = NSScreen.screens.compactMap(Self.describe)
    }

    private static func describe(_ screen: NSScreen) -> DisplayInfo? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let id = CGDirectDisplayID(number.uint32Value)

        // `width`/`height` are the point grid the desktop uses. Fall back to the frame if no mode.
        let mode = CGDisplayCopyDisplayMode(id)
        let pointW = mode.map(\.width) ?? Int(screen.frame.width)
        let pointH = mode.map(\.height) ?? Int(screen.frame.height)

        // A built-in panel commonly reports 0 here rather than its real rate; treat that as unknown
        // instead of printing "0 Hz".
        let hz = mode.map(\.refreshRate).flatMap { $0 > 0 ? $0 : nil }

        let native = Self.nativeGrid(id)
        let mm = CGDisplayScreenSize(id)
        return DisplayInfo(
            id: id,
            name: screen.localizedName,
            pointWidth: pointW, pointHeight: pointH,
            nativeWidth: native?.width, nativeHeight: native?.height,
            refreshHz: hz,
            scale: Double(screen.backingScaleFactor),
            isBuiltIn: CGDisplayIsBuiltin(id) != 0,
            isMain: CGDisplayIsMain(id) != 0,
            physicalMM: (mm.width > 0 && mm.height > 0) ? mm : nil
        )
    }

    /// The panel's real pixel grid: the largest mode whose point size equals its pixel size, i.e. a
    /// true 1:1 mode.
    ///
    /// Explicitly NOT the current mode's `pixelWidth`/`pixelHeight`. Under a non-integer "scaled"
    /// setting — the factory default on 14"/16" MacBook Pros — that is a supersampling buffer LARGER
    /// than the panel: this 14" reports 3600×2338 for a display that is physically 3024×1964, a
    /// number that appears nowhere in macOS's own UI and describes no physical thing.
    /// `kCGDisplayShowDuplicateLowResolutionModes` is required, or the 1:1 modes are filtered out of
    /// the list entirely and there is nothing left to pick from.
    private static func nativeGrid(_ id: CGDirectDisplayID) -> (width: Int, height: Int)? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return nil }
        let oneToOne = modes.filter { $0.width == $0.pixelWidth && $0.height == $0.pixelHeight }
        guard let best = oneToOne.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight })
        else { return nil }
        return (best.pixelWidth, best.pixelHeight)
    }
}
