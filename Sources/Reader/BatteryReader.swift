// BatteryReader.swift — reads the Mac's battery straight from the IOKit "AppleSmartBattery"
// registry (the same source coconutBattery uses — no root, no kernel extension) plus the live
// SMC power rails, and publishes a BatteryInfo on the main thread.

import Foundation
import Combine
import IOKit
import IOKit.ps

@MainActor
final class BatteryReader: ObservableObject {
    @Published var info = BatteryInfo()
    private lazy var poll = PollingTimer { [weak self] in self?.refresh() }
    // "Is anyone looking?" — the detail popover is open, or the battery menu-bar item is visible.
    // With neither, nothing shows the data, so the reader stops polling entirely (see applyCadence).
    // itemVisible defaults true to match AppDelegate's lenient "absent key ⇒ shown" default.
    private var panelOpen = false
    private var itemVisible = true
    private let smc = SMC.shared

    /// Power-source change notifications (plug/unplug, charging state, charge %) trigger an immediate
    /// refresh, so the menu-bar glyph reacts at once even though the closed-panel poll is slow — that's
    /// what lets idleInterval be lazy without the charging bolt / % lagging behind reality. Retained so
    /// it can be removed in deinit.
    private var powerSourceMonitor: CFRunLoopSource?

    // "Maximum Capacity" (macOS's own battery-health figure — System Information / Battery Health)
    // has no public IOKit key: Apple computes it with a private, smoothed algorithm that no raw
    // ratio reproduces. So we read the exact value macOS reports from `system_profiler`, but only
    // every few minutes on a background queue — battery health drifts over weeks, never per-second,
    // so the 1 Hz gauge path below never pays that cost. cachedMaxCapacity is touched on main only.
    private var cachedMaxCapacity: Int?
    private lazy var healthRead = ThrottledBackgroundValue<Int?>(label: "BatteryReader.health", every: 300)

    // Closed popover: a slow backstop poll — the full IOKit property-dict read is materialized every
    // tick, so doing it once a second all day (86,400×) for a glyph whose charge % moves ~once a
    // minute is wasteful. Power-source notifications (see startPowerSourceMonitor) cover the changes
    // that actually matter for the glyph, so the poll only needs to catch the rest occasionally.
    private static let idleInterval: TimeInterval = 10
    private static let activeInterval: TimeInterval = 1  // live readout while the detail panel is open

    init() {
        refresh()
        poll.schedule(every: Self.idleInterval)
        startPowerSourceMonitor()
    }

    /// Refresh the instant the power source changes (charger plugged/unplugged, charging↔not, a new
    /// charge %), so the menu-bar glyph stays live between the lazy idle polls. The C callback can't
    /// capture, so `self` is passed through the context pointer (unretained — BatteryReader lives for
    /// the whole app run, owned by AppDelegate). The source is added to the main run loop, so the
    /// callback fires on main and refresh() stays main-thread-only like every other call site.
    private func startPowerSourceMonitor() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryReader>.fromOpaque(ctx).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceMonitor = source
    }

    deinit {
        if let source = powerSourceMonitor {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    /// Poll fast while the detail panel is visible; drop back to the lazy cadence when it closes (or
    /// stop entirely if the menu-bar item is also hidden — see applyCadence).
    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        applyCadence()
        if open { refresh() }
    }

    /// Driven by AppDelegate off the "showBatteryItem" toggle. When the item is hidden and the popover
    /// is closed, nothing shows the battery — stop reading; when it's shown again, repaint now.
    func setItemVisible(_ visible: Bool) {
        guard visible != itemVisible else { return }
        itemVisible = visible
        applyCadence()
        if visible && !panelOpen { refresh() }
    }

    /// Poll cadence from the two visibility signals: fast in the popover, lazy for the menu-bar glyph
    /// alone, stopped when neither shows the data.
    private func applyCadence() {
        if panelOpen { poll.schedule(every: Self.activeInterval) }
        else if itemVisible { poll.schedule(every: Self.idleInterval) }
        else { poll.stop() }
    }

    func refresh() {
        // Nothing displays the battery when the popover is closed and the item is hidden — skip the
        // read (the poll is already stopped; this also covers the power-source notification callback).
        guard panelOpen || itemVisible else { return }

        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef,
                                                kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { return }

        // Which key holds which figure is SmartBatteryRegistry's job, in Sources/Core. macOS moves
        // them between releases just as iOS does — macOS 27 emptied the top level of every mAh key —
        // and the way that went wrong here was not an empty card but a plausible one. The block this
        // replaces fell back to "MaxCapacity"/"CurrentCapacity" when the AppleRaw* keys read zero,
        // which was right on Intel, where those keys really did hold mAh, and became "Full charge
        // capacity: 100 mAh" above "Design capacity: 0 mAh" the moment they turned into percentages.
        // See that type's header; the unit separation lives there, with the tests.
        // The gauge's own entry, AppleSmartBatteryPack, kept the vocabulary macOS 27 removed from the
        // one above — Temperature and the AppleRaw* mAh keys, nested in a BatteryData of its own. Read
        // only when the entry is short of what the pack has, so a machine still on the old layout does
        // exactly what it did before, and in-process, so it costs a registry lookup and not a fork.
        let pack = SmartBatteryRegistry.wantsPack(props) ? Self.registryProperties(ofClass: "AppleSmartBatteryPack") : nil
        let batt = SmartBatteryRegistry.parse(props, pack: pack)

        var i = BatteryInfo()
        i.deviceName = props["DeviceName"] as? String ?? "Battery"
        i.serial = props["Serial"] as? String ?? ""
        i.designCapacity = batt.designCapacity ?? 0
        i.maxCapacity = batt.maxCapacity ?? 0
        i.currentCapacity = batt.currentCapacity ?? 0

        // State of Charge — the calibrated 0–100 % macOS reports (System Information's
        // "State of Charge (%)"), NOT the raw mAh ratio. The parser derives it from the relative
        // "CurrentCapacity"/"MaxCapacity" pair, which is a percentage pair on Apple Silicon and an
        // mAh pair on Intel that yields the same percentage. The raw-mAh fallback below is kept from
        // the previous implementation for a pack that publishes no relative max at all.
        i.stateOfCharge = batt.stateOfCharge
            ?? (i.maxCapacity > 0 ? min(100, Double(i.currentCapacity) / Double(i.maxCapacity) * 100) : 0)

        i.cycleCount = batt.cycleCount ?? 0
        // Rated cycle life. Apple names it DesignCycleCount9C (1000 on this M1 Pro); it sits in the
        // dictionary already fetched above, so reading it costs nothing.
        i.designCycleCount = intOf(props["DesignCycleCount9C"])
        // From the entry or the pack; a Mac publishing neither gets the SMC further down, while the
        // panel is open. Nil reaching the view hides the row, which is the point — the previous line
        // divided a missing key by 100 and presented the result as 0.0 °C.
        i.temperatureC = batt.temperatureC
        i.voltageV = batt.voltageV ?? 0
        i.amperageA = batt.amperageA ?? 0
        i.isCharging = batt.isCharging
        i.externalConnected = batt.externalConnected
        i.fullyCharged = batt.fullyCharged
        i.timeToEmpty = intOf(props["AvgTimeToEmpty"])
        i.timeToFull = intOf(props["AvgTimeToFull"])

        if let ad = props["AdapterDetails"] as? [String: Any] {
            i.adapterWatts = intOf(ad["Watts"])
            i.adapterName = (ad["Name"] as? String)
                ?? (ad["Description"] as? String) ?? ""
        }

        // DC in — total power the machine is drawing from the charger (Apple Silicon: BatteryData.AdapterPower)
        if let bd = props["BatteryData"] as? [String: Any],
           let p = bd["AdapterPower"] as? NSNumber {
            i.adapterPower = p.doubleValue
        }

        // Live SMC power rails + fan speeds (these move every second — see the header note on
        // BatteryInfo). They are detail-panel-only content, so skip the SMC user-client round-trips
        // while the panel is closed — the menu-bar glyph needs only the IOKit charge fields read
        // above. Matches the popover-gating every other reader does (cf. CPUReader's temperature read).
        if panelOpen {
            // Last resort for the pack temperature, when neither registry entry publishes one. Behind
            // the same gate as the rails because it is the same kind of cost and shows in the same rows.
            if i.temperatureC == nil { i.temperatureC = smcBatteryTemperature() }
            i.smcSystemTotalW  = smc.readFloat("PSTR")
            i.smcDCInW         = smc.readFloat("PDTR")
            i.smcBrightnessW   = smc.readFloat("PDBR")
            i.smcThunderboltLW = smc.readFloat("PU1R")
            i.smcThunderboltRW = smc.readFloat("PU2R")
            i.smcPPBRW         = smc.readFloat("PPBR")
            i.fans = smc.readFans()
        }

        // macOS's own "Maximum Capacity" is a detail-panel-only figure (the menu-bar glyph never
        // shows battery health) and each refresh forks system_profiler, so only fetch it while the
        // popover is open — same popover-gating as the SMC rails above. The cached value is still
        // published unconditionally, so the panel shows the last-known figure immediately on open
        // while a fresh read lands a moment later.
        if panelOpen { maybeReadMaximumCapacity() }
        i.maximumCapacityPercent = cachedMaxCapacity

        // refresh() only ever runs on the main thread (init / setPanelOpen / the main-run-loop poll),
        // so publish directly rather than hopping to the next run-loop pass.
        info = i
    }

    /// The property dictionary of the first registry entry of `cls`, or nil when there is none.
    private static func registryProperties(ofClass cls: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(cls))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var ref: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &ref, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return ref?.takeRetainedValue() as? [String: Any]
    }

    /// The battery pack temperature from the SMC, in °C, or nil on a Mac that publishes no pack
    /// sensor. The tier below both registry entries: on this macOS 27 machine the pack entry answers
    /// first and this is never reached, but a Mac can ask its own SMC where an iPhone over lockdown
    /// cannot, and that is worth keeping for a machine that publishes neither key.
    ///
    /// TB0T/TB1T/TB2T are the pack's sensors. They were identified as the pack's rather than
    /// something nearby by reading all 210 T-prefixed keys at once on the J314s measured here: those
    /// three sat at 33.2/33.2/32.1 °C while every TC** CPU-die key beside them read 47–52 °C.
    ///
    /// The hottest of the three is reported, not their mean: they are separate sensors on one pack,
    /// and a figure whose job is to say the battery is hot should not average that away. A reading of
    /// exactly zero is dropped rather than trusted — on this machine the two TH1* drive sensors read
    /// 0.00 for a bay that is not populated, so zero is how this SMC spells "no sensor here", and
    /// letting one through would put back the 0.0 °C row this change exists to remove.
    private func smcBatteryTemperature() -> Double? {
        ["TB0T", "TB1T", "TB2T"].compactMap { smc.readFloat($0) }.filter { $0 > 0 }.max()
    }

    /// Refresh macOS's "Maximum Capacity" at most every few minutes, off the main thread. Called from
    /// `refresh()` (main); the read runs on a background queue and the result lands back on main, so
    /// cachedMaxCapacity is only ever touched there. Nil reads are ignored (keep the last value).
    private func maybeReadMaximumCapacity() {
        healthRead.request(produce: { Self.readMaximumCapacity() }) { [weak self] value in
            if let value { self?.cachedMaxCapacity = value }
        }
    }

    /// The integer percent from `system_profiler`'s "Maximum Capacity: NN%" line, or nil on failure.
    /// Reuses DeviceTool.run for its timeout + concurrent pipe draining (system_profiler is fast,
    /// ~0.2 s, but this keeps a wedged process from ever hanging the health queue).
    nonisolated private static func readMaximumCapacity() -> Int? {
        guard let data = DeviceTool.run("/usr/sbin/system_profiler", ["SPPowerDataType"]),
              let out = String(data: data, encoding: .utf8) else { return nil }
        for line in out.split(separator: "\n") where line.contains("Maximum Capacity") {
            let digits = String(line.filter(\.isNumber))
            if let n = Int(digits), n > 0, n <= 100 { return n }
        }
        return nil
    }
}
