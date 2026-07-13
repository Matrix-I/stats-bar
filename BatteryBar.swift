// BatteryBar.swift — Menu bar battery health app, coconutBattery-style
//
// Requires : macOS 13 Ventura or later + Xcode Command Line Tools
//            (xcode-select --install)
//
// Quick run     :  swiftc -O -parse-as-library BatteryBar.swift -o BatteryBar && ./BatteryBar
// Package .app  :  ./build_app.sh
//
// Data is read directly from the IOKit registry "AppleSmartBattery" — the same
// source coconutBattery uses. No root needed, no kernel extension.

import SwiftUI
import AppKit
import IOKit
import Foundation

// MARK: - Model

struct BatteryInfo {
    var deviceName = "Battery"
    var serial = ""
    var currentCapacity = 0      // mAh
    var maxCapacity = 0          // mAh — actual full charge capacity
    var designCapacity = 0       // mAh — design capacity
    var cycleCount = 0
    var temperatureC = 0.0
    var voltageV = 0.0
    var amperageA = 0.0          // negative = discharging, positive = charging
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    var timeToEmpty = 0          // minutes (65535 = still calculating)
    var timeToFull = 0           // minutes
    var adapterWatts = 0
    var adapterName = ""
    var adapterPower = 0.0        // W — actual DC in power drawn from the charger (BatteryData.AdapterPower)

    var chargePercent: Double {
        maxCapacity > 0 ? Double(currentCapacity) / Double(maxCapacity) * 100 : 0
    }
    var healthPercent: Double {
        designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) * 100 : 0
    }
    var watts: Double { voltageV * amperageA }
}

// MARK: - IOKit reader

final class BatteryReader: ObservableObject {
    @Published var info = BatteryInfo()
    private var timer: Timer?
    private var interval: TimeInterval = 0

    private static let idleInterval: TimeInterval = 5    // menu-bar glyph only needs the occasional tick
    private static let activeInterval: TimeInterval = 1  // live readout while the detail panel is open

    init() {
        refresh()
        schedule(Self.idleInterval)
    }

    private func schedule(_ seconds: TimeInterval) {
        guard seconds != interval else { return }
        interval = seconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Poll once a second while the detail panel is visible; drop back to the lazy cadence when it closes.
    func setPanelOpen(_ open: Bool) {
        schedule(open ? Self.activeInterval : Self.idleInterval)
        if open { refresh() }
    }

    func refresh() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef,
                                                kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { return }

        var i = BatteryInfo()
        i.deviceName = props["DeviceName"] as? String ?? "Battery"
        i.serial = props["Serial"] as? String ?? ""
        i.designCapacity = intOf(props["DesignCapacity"])

        // Apple Silicon: AppleRaw* holds the real mAh values; older Intel: fall back to Max/CurrentCapacity
        i.maxCapacity = intOf(props["AppleRawMaxCapacity"])
        if i.maxCapacity == 0 { i.maxCapacity = intOf(props["MaxCapacity"]) }
        i.currentCapacity = intOf(props["AppleRawCurrentCapacity"])
        if i.currentCapacity == 0 { i.currentCapacity = intOf(props["CurrentCapacity"]) }

        i.cycleCount = intOf(props["CycleCount"])
        i.temperatureC = Double(intOf(props["Temperature"])) / 100.0
        i.voltageV = Double(intOf(props["Voltage"])) / 1000.0
        i.amperageA = Double(signedIntOf(props["Amperage"])) / 1000.0
        i.isCharging = props["IsCharging"] as? Bool ?? false
        i.externalConnected = props["ExternalConnected"] as? Bool ?? false
        i.fullyCharged = props["FullyCharged"] as? Bool ?? false
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

        let snapshot = i
        DispatchQueue.main.async { self.info = snapshot }
    }
}

// MARK: - IOKit value helpers (shared by the Mac + iOS readers)

func intOrNil(_ any: Any?) -> Int? {
    (any as? NSNumber)?.intValue
}

func intOf(_ any: Any?) -> Int {
    intOrNil(any) ?? 0
}

/// IOKit sometimes returns negative numbers as unsigned 32-bit (e.g. Amperage while discharging)
func signedIntOrNil(_ any: Any?) -> Int? {
    guard let n = any as? NSNumber else { return nil }
    var v = n.int64Value
    if v > 0x7FFF_FFFF && v <= 0xFFFF_FFFF { v -= 0x1_0000_0000 }
    return Int(v)
}

func signedIntOf(_ any: Any?) -> Int {
    signedIntOrNil(any) ?? 0
}

// MARK: - iOS device model (iPhone/iPad over USB)

struct IOSDeviceInfo: Identifiable {
    let id: String               // UDID
    var name = ""
    var model = ""
    var iosVersion = ""
    var serial = ""
    var currentCapacity: Int?     // mAh — nil if diagnostics doesn't return this key
    var maxCapacity: Int?
    var designCapacity: Int?
    var cycleCount: Int?
    var temperatureC: Double?
    var voltageV: Double?
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    var errorMessage: String?
    var isStale = false           // true = currently showing the last known data because the connection briefly dropped
    var capturedAt: Date?         // timestamp this data was captured

    var chargePercent: Double? {
        guard let cur = currentCapacity, let max = maxCapacity, max > 0 else { return nil }
        return Double(cur) / Double(max) * 100
    }
    var healthPercent: Double? {
        guard let max = maxCapacity, max > 0, let design = designCapacity, design > 0 else { return nil }
        return Double(max) / Double(design) * 100
    }
}

// MARK: - iOS device reader (shells out to libimobiledevice, same approach as cocobat.py --ios)

final class IOSDeviceReader: ObservableObject {
    @Published var devices: [IOSDeviceInfo] = []
    @Published var toolsMissing = false
    @Published var statusMessage: String?

    /// Only accessed/mutated on the main thread — refresh() is always called from main (button, onAppear, timer).
    private var isBusy = false
    private var timer: Timer?

    /// Cache of the most recently read devices (only touched on the main thread, inside publish) —
    /// used to keep showing data when the USB connection drops briefly instead of the device "vanishing".
    private var lastGood: [IOSDeviceInfo] = []
    private var lastGoodAt: Date?
    private static let staleGrace: TimeInterval = 90   // seconds

    private static let searchDirs = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"]

    init() {
        refresh()
        // MenuBarExtra(.window) builds the view once and just shows/hides it afterward — .onAppear
        // doesn't refire on every menu open, so a dedicated timer is needed to pick up plug/unplug events.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.doRefresh()
        }
    }

    private func toolPath(_ name: String) -> String? {
        for dir in Self.searchDirs {
            let p = dir + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Runs a command, returns stdout if exit code is 0, nil otherwise. Reads both pipes concurrently —
    /// reading them sequentially (stdout then stderr) can deadlock if the child process fills the
    /// stderr buffer while we're still waiting for EOF on stdout.
    private func run(_ path: String, _ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return nil
        }

        let group = DispatchGroup()
        var outData = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? outData : nil
    }

    private func infoValue(_ path: String, udid: String, key: String) -> String? {
        guard let data = run(path, ["-u", udid, "-k", key]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Lists UDIDs, retrying a few times since the USB connection (usbmux) can drop for a few
    /// seconds, especially when the device is locked or another app is holding the lockdown session.
    private func listUDIDs(_ path: String) -> [String] {
        for attempt in 0..<5 {
            if let data = run(path, ["-l"]),
               let s = String(data: data, encoding: .utf8) {
                let udids = s.split(whereSeparator: \.isNewline)
                    .map(String.init).filter { !$0.isEmpty }
                if !udids.isEmpty { return udids }
            }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.4) }
        }
        return []
    }

    /// Reads ioregentry AppleSmartBattery, retrying since diagnostics also drops out temporarily.
    private func readBatteryRegistry(_ path: String, udid: String) -> [String: Any]? {
        for attempt in 0..<3 {
            if let raw = run(path, ["-u", udid, "ioregentry", "AppleSmartBattery"]),
               let plist = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil) as? [String: Any],
               let reg = plist["IORegistry"] as? [String: Any] {
                return reg
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.3) }
        }
        return nil
    }

    private func doRefresh() {
        guard let ideviceIdPath = toolPath("idevice_id"),
              let ideviceInfoPath = toolPath("ideviceinfo"),
              let diagnosticsPath = toolPath("idevicediagnostics") else {
            publish(devices: [], toolsMissing: true, status: nil)
            return
        }

        let udids = listUDIDs(ideviceIdPath)
        guard !udids.isEmpty else {
            publish(devices: [], toolsMissing: false,
                    status: "No iPhone/iPad found over USB.\nPlug in the cable, unlock the device, tap Trust.")
            return
        }

        var results: [IOSDeviceInfo] = []
        for udid in udids {
            var dev = IOSDeviceInfo(id: udid)
            dev.name = infoValue(ideviceInfoPath, udid: udid, key: "DeviceName") ?? udid
            dev.model = infoValue(ideviceInfoPath, udid: udid, key: "ProductType") ?? ""
            dev.iosVersion = infoValue(ideviceInfoPath, udid: udid, key: "ProductVersion") ?? ""

            guard let reg = readBatteryRegistry(diagnosticsPath, udid: udid) else {
                dev.errorMessage = "Couldn't read diagnostics — unlock the device + tap Trust."
                results.append(dev)
                continue
            }

            dev.serial = reg["Serial"] as? String ?? ""
            dev.designCapacity = intOrNil(reg["DesignCapacity"])
            dev.maxCapacity = intOrNil(reg["AppleRawMaxCapacity"]) ?? intOrNil(reg["NominalChargeCapacity"])
            dev.currentCapacity = intOrNil(reg["AppleRawCurrentCapacity"])
            dev.cycleCount = intOrNil(reg["CycleCount"])
            if let t = intOrNil(reg["Temperature"]) { dev.temperatureC = Double(t) / 100.0 }
            if let v = intOrNil(reg["Voltage"]) { dev.voltageV = Double(v) / 1000.0 }
            dev.isCharging = reg["IsCharging"] as? Bool ?? false
            dev.externalConnected = reg["ExternalConnected"] as? Bool ?? false
            dev.fullyCharged = reg["FullyCharged"] as? Bool ?? false
            dev.capturedAt = Date()

            results.append(dev)
        }

        publish(devices: results, toolsMissing: false, status: nil)
    }

    private func publish(devices fresh: [IOSDeviceInfo], toolsMissing: Bool, status: String?) {
        DispatchQueue.main.async {
            self.isBusy = false

            if toolsMissing {
                self.toolsMissing = true
                self.devices = []
                self.statusMessage = nil
                return
            }
            self.toolsMissing = false

            let now = Date()
            let graceOK = self.lastGoodAt.map { now.timeIntervalSince($0) < Self.staleGrace } ?? false

            // Empty enumeration (flaky connection) → keep the device we just saw if still within the grace period.
            if fresh.isEmpty {
                if graceOK, !self.lastGood.isEmpty {
                    self.devices = self.lastGood.map { var d = $0; d.isStale = true; return d }
                    self.statusMessage = nil
                } else {
                    self.devices = []
                    self.statusMessage = status
                        ?? "No iPhone/iPad found over USB.\nPlug in the cable, unlock the device, tap Trust."
                }
                return
            }

            // Enumeration succeeded: any device whose diagnostics read failed reuses the last good data.
            var merged: [IOSDeviceInfo] = []
            for dev in fresh {
                if dev.errorMessage != nil, graceOK,
                   let prev = self.lastGood.first(where: { $0.id == dev.id }) {
                    var s = prev; s.isStale = true
                    merged.append(s)
                } else {
                    merged.append(dev)
                }
            }
            self.devices = merged
            self.statusMessage = nil

            // Update the cache with devices that currently have good data (including reused ones).
            let good = merged.filter { $0.errorMessage == nil }
                .map { var d = $0; d.isStale = false; return d }
            if !good.isEmpty {
                self.lastGood = good
                self.lastGoodAt = now
            }
        }
    }
}

// MARK: - Helpers

func healthColor(_ p: Double) -> Color {
    p >= 80 ? .green : (p >= 60 ? .orange : .red)
}

func fmtMinutes(_ m: Int) -> String { "\(m / 60)h \(String(format: "%02d", m % 60))m" }

// MARK: - Views

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

/// Draws the menu-bar battery as a resolution-independent **template** NSImage:
/// horizontal outline + terminal nub, an inner fill proportional to the real charge
/// level, and (when charging) a bolt punched out via `.destinationOut`. A template
/// image is the reliable way to render a custom menu-bar glyph — the system tints it
/// to match the menu bar (white on dark, black on light). A SwiftUI shape view with
/// blend modes instead rendered as a solid dark blob, because `.primary` didn't adapt
/// and the compositing flattened wrong. SF Symbols only ship `.bolt` for the 100%
/// variant, so drawing it ourselves is the only way to show a partial charging battery.
func batteryMenuBarImage(level: Double, charging: Bool, percent: Int? = nil) -> NSImage {
    let h: CGFloat = 13
    let lw: CGFloat = 1.2

    // --- Number-inside style: the % sits inside the battery body, so there's no
    // separate label and therefore no left/right ordering to get wrong. Width grows
    // to fit 1–3 digits (plus a bolt when charging). ---
    if let percent {
        let text = "\(percent)" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = text.size(withAttributes: attrs)
        let boltW: CGFloat = charging ? 5 : 0
        let padX: CGFloat = 2.8
        let bodyW = padX + boltW + ceil(textSize.width) + padX
        let w = bodyW + 3.6

        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let bodyRect = NSRect(x: lw / 2, y: lw / 2, width: bodyW, height: h - lw)
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: bodyRect, xRadius: 3.4, yRadius: 3.4)
            outline.lineWidth = lw
            outline.stroke()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: bodyW + 0.6, y: h / 2 - 2.4, width: 1.7, height: 4.8),
                         xRadius: 0.8, yRadius: 0.8).fill()

            var textX = bodyRect.minX + padX
            if charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
                let bh = h - 4.5, bw = bh * (bolt.size.width / max(bolt.size.height, 1))
                bolt.draw(in: NSRect(x: bodyRect.minX + 1.6, y: h / 2 - bh / 2, width: bw, height: bh),
                          from: .zero, operation: .sourceOver, fraction: 1)
                textX = bodyRect.minX + 1.6 + bw + 0.8
            }
            // Vertically centre the digits (nudge for the font's internal leading).
            text.draw(at: NSPoint(x: textX, y: (h - textSize.height) / 2 + 0.3), withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        return img
    }

    // --- Fill style: used when the % is hidden — a plain glyph with a proportional fill. ---
    let w: CGFloat = 25
    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
        let bodyW = w - 3.6                       // leave room for the terminal nub
        let bodyRect = NSRect(x: lw / 2, y: lw / 2, width: bodyW, height: h - lw)
        NSColor.black.setStroke()                 // color ignored for templates; only alpha matters
        let outline = NSBezierPath(roundedRect: bodyRect, xRadius: 3.4, yRadius: 3.4)
        outline.lineWidth = lw
        outline.stroke()

        let inner = bodyRect.insetBy(dx: lw + 0.7, dy: lw + 0.7)
        let fillW = max(1.5, inner.width * min(max(level, 0), 1))
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: fillW, height: inner.height),
                     xRadius: 1.6, yRadius: 1.6).fill()

        NSBezierPath(roundedRect: NSRect(x: bodyW + 0.6, y: h / 2 - 2.4, width: 1.7, height: 4.8),
                     xRadius: 0.8, yRadius: 0.8).fill()

        if charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
            let bh = h * 0.92, bw = bh * (bolt.size.width / max(bolt.size.height, 1))
            let br = NSRect(x: bodyRect.midX - bw / 2, y: h / 2 - bh / 2, width: bw, height: bh)
            bolt.draw(in: br, from: .zero, operation: .destinationOut, fraction: 1)
        }
        return true
    }
    img.isTemplate = true
    return img
}

/// Thin SwiftUI wrapper around the template battery image.
struct BatteryGlyph: View {
    let level: Double        // 0…1
    let charging: Bool
    var percent: Int? = nil  // when set, the number is drawn inside the battery
    var body: some View {
        Image(nsImage: batteryMenuBarImage(level: level, charging: charging, percent: percent))
    }
}

/// Mac + iPhone in one menu-bar item: laptop glyph + Mac battery, then iPhone glyph +
/// iPhone battery, all composited into a SINGLE template image. Baking it avoids the
/// HStack reordering the real MenuBarExtra applies to multi-view labels.
func dualMenuBarImage(macPct: Int, macCharging: Bool, iosPct: Int, iosCharging: Bool) -> NSImage {
    let h: CGFloat = 13, symH: CGFloat = 10
    let macBat = batteryMenuBarImage(level: Double(macPct) / 100, charging: macCharging, percent: macPct)
    let iosBat = batteryMenuBarImage(level: Double(iosPct) / 100, charging: iosCharging, percent: iosPct)
    func symbol(_ name: String) -> NSImage? {
        guard let s = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        s.isTemplate = true
        return s
    }
    let laptop = symbol("laptopcomputer"), phone = symbol("iphone")
    func widthOf(_ img: NSImage?) -> CGFloat {
        guard let img else { return 0 }
        return symH * (img.size.width / max(img.size.height, 1))
    }
    let laptopW = widthOf(laptop), phoneW = widthOf(phone)
    let gap: CGFloat = 2.5, bigGap: CGFloat = 6
    let total = laptopW + gap + macBat.size.width + bigGap + phoneW + gap + iosBat.size.width

    let img = NSImage(size: NSSize(width: total, height: h), flipped: false) { _ in
        var x: CGFloat = 0
        laptop?.draw(in: NSRect(x: x, y: (h - symH) / 2, width: laptopW, height: symH),
                     from: .zero, operation: .sourceOver, fraction: 1)
        x += laptopW + gap
        macBat.draw(in: NSRect(x: x, y: 0, width: macBat.size.width, height: h),
                    from: .zero, operation: .sourceOver, fraction: 1)
        x += macBat.size.width + bigGap
        phone?.draw(in: NSRect(x: x, y: (h - symH) / 2, width: phoneW, height: symH),
                    from: .zero, operation: .sourceOver, fraction: 1)
        x += phoneW + gap
        iosBat.draw(in: NSRect(x: x, y: 0, width: iosBat.size.width, height: h),
                    from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
    img.isTemplate = true
    return img
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

struct IOSDeviceRow: View {
    let device: IOSDeviceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(device.name).font(.caption).fontWeight(.semibold).lineLimit(1)
                Spacer()
                let sub = [device.model.isEmpty ? nil : device.model,
                           device.iosVersion.isEmpty ? nil : "iOS \(device.iosVersion)"]
                    .compactMap { $0 }.joined(separator: " · ")
                if !sub.isEmpty {
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if device.isStale {
                Text("⟳ last known data — USB connection reconnecting")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if let err = device.errorMessage {
                Text(err).font(.caption2).foregroundStyle(.red)
            } else if device.chargePercent == nil && device.healthPercent == nil {
                Text("⚠ Couldn't read health data — unlock the device + Trust, then tap Refresh.")
                    .font(.caption2).foregroundStyle(.orange)
            } else {
                if let cp = device.chargePercent {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Charge").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f%%", cp)).font(.caption).fontWeight(.medium).monospacedDigit()
                    }
                    BarView(pct: cp, color: .blue)
                }
                if let hp = device.healthPercent {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Health").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f%%", hp))
                            .font(.caption).fontWeight(.medium).monospacedDigit()
                            .foregroundStyle(healthColor(hp))
                    }
                    BarView(pct: hp, color: healthColor(hp))
                }
                if let cc = device.cycleCount {
                    InfoRow(label: "Cycle count", value: "\(cc)")
                }
                if let t = device.temperatureC {
                    InfoRow(label: "Temperature", value: String(format: "%.1f °C", t))
                }
                if let v = device.voltageV {
                    InfoRow(label: "Voltage", value: String(format: "%.2f V", v))
                }
                if device.externalConnected {
                    InfoRow(label: "Status",
                            value: device.isCharging ? "Charging"
                                : (device.fullyCharged ? "Fully charged" : "Plugged in, not charging"))
                }
                if !device.serial.isEmpty {
                    InfoRow(label: "Serial", value: device.serial)
                }
            }
        }
    }
}

struct IOSDevicesSection: View {
    @ObservedObject var reader: IOSDeviceReader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📱 iPhone / iPad (USB)").font(.caption).foregroundStyle(.secondary)

            if reader.toolsMissing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Missing libimobiledevice.").font(.caption2).foregroundStyle(.orange)
                    Text("brew install libimobiledevice")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else if let status = reader.statusMessage {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            } else if reader.devices.isEmpty {
                Text("No devices connected.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                // No ScrollView here: SwiftUI's ScrollView has no well-defined ideal height inside
                // an auto-sizing MenuBarExtra(.window) popover, so it was rendering at ~0 height —
                // the section looked empty even though `devices` held real data. A plain VStack
                // always has a proper intrinsic size, so let the popover grow to fit instead.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(reader.devices) { device in
                        IOSDeviceRow(device: device)
                        if device.id != reader.devices.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

/// Reports when the hosting window becomes visible / hidden. MenuBarExtra(.window) builds its
/// content once and just orders the popover window in and out, so SwiftUI's `.onAppear` doesn't
/// refire per open — observing the NSWindow directly is the reliable signal. `isVisible` tracks
/// ordered-in state (not mere occlusion), so covering the popover doesn't count as "closed".
final class WindowVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private weak var observed: NSWindow?
    private var lastReported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== observed else { evaluate(); return }
        let nc = NotificationCenter.default
        if let old = observed { nc.removeObserver(self, name: nil, object: old) }
        observed = window
        if let window {
            for name: NSNotification.Name in [NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification,
                                              NSWindow.didChangeOcclusionStateNotification,
                                              NSWindow.willCloseNotification] {
                nc.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
        }
        evaluate()
    }

    @objc private func windowChanged() {
        // Defer so order-out has settled before we read isVisible.
        DispatchQueue.main.async { [weak self] in self?.evaluate() }
    }

    private func evaluate() {
        let visible = observed?.isVisible ?? false
        guard visible != lastReported else { return }
        lastReported = visible
        onChange?(visible)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

struct WindowVisibilityReporter: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> WindowVisibilityView {
        let v = WindowVisibilityView(); v.onChange = onChange; return v
    }
    func updateNSView(_ nsView: WindowVisibilityView, context: Context) { nsView.onChange = onChange }
}

struct BatteryDetailView: View {
    @ObservedObject var reader: BatteryReader
    @ObservedObject var iosReader: IOSDeviceReader
    @AppStorage("showMenuBarPercent") private var showMenuBarPercent = true
    @AppStorage("showIPhoneMenuBar") private var showIPhoneMenuBar = false

    var body: some View {
        let i = reader.info
        VStack(alignment: .leading, spacing: 12) {

            // Header
            HStack {
                Text("🔋 Battery").font(.headline)
                Spacer()
                Text(i.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Current charge
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Current charge")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", i.chargePercent))
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                }
                BarView(pct: i.chargePercent, color: .blue)
                Text("\(i.currentCapacity) / \(i.maxCapacity) mAh")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }

            // Health
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Health (vs design)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", i.healthPercent))
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(healthColor(i.healthPercent))
                }
                BarView(pct: i.healthPercent, color: healthColor(i.healthPercent))
                Text("\(i.maxCapacity) / \(i.designCapacity) mAh (design)")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }

            Divider()

            VStack(spacing: 6) {
                InfoRow(label: "Cycle count", value: "\(i.cycleCount)")
                InfoRow(label: "Temperature",
                        value: String(format: "%.1f °C", i.temperatureC))
                InfoRow(label: "Voltage",
                        value: String(format: "%.2f V", i.voltageV))
                InfoRow(label: "Power", value: powerText(i))
                if i.externalConnected && i.adapterWatts > 0 {
                    InfoRow(label: "Adapter",
                            value: "\(i.adapterWatts) W \(i.adapterName)")
                }
                InfoRow(label: "Status", value: statusText(i))
                if !i.serial.isEmpty {
                    InfoRow(label: "Serial", value: i.serial)
                }
            }

            Divider()

            IOSDevicesSection(reader: iosReader)
                .onAppear { iosReader.refresh() }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show % in menu bar", isOn: $showMenuBarPercent)
                Toggle("Show iPhone in menu bar", isOn: $showIPhoneMenuBar)
            }
            .font(.caption)
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            HStack {
                Button("Refresh") {
                    reader.refresh()
                    iosReader.refresh()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
        .background(WindowVisibilityReporter { open in
            reader.setPanelOpen(open)
            if open { iosReader.refresh() }   // one immediate iOS read on open; it stays on its slow cadence
        })
    }

    private func powerText(_ i: BatteryInfo) -> String {
        // Plugged in: show DC in (power drawn from the charger). On battery: show discharge power.
        if i.externalConnected {
            if i.adapterPower > 0.05 {
                return String(format: "%.1f W (DC in)", i.adapterPower)
            }
            // Fallback for machines that don't expose AdapterPower (e.g. Intel): power flowing into the battery
            let charge = i.watts
            return charge > 0.05 ? String(format: "%.1f W (charging battery)", charge) : "—"
        }
        let w = abs(i.watts)
        return w < 0.05 ? "0 W" : String(format: "%.1f W (discharging)", w)
    }

    private func statusText(_ i: BatteryInfo) -> String {
        if i.fullyCharged && i.externalConnected { return "Fully charged" }
        if i.isCharging {
            return (1..<65535).contains(i.timeToFull)
                ? "Full in ~\(fmtMinutes(i.timeToFull))" : "Charging"
        }
        if i.externalConnected { return "Plugged in, not charging" }
        return (1..<65535).contains(i.timeToEmpty)
            ? "~\(fmtMinutes(i.timeToEmpty)) remaining" : "On battery"
    }
}

/// Single menu bar item. Mac-only: one line, battery-shape icon (+ optional %).
/// With "Show iPhone in menu bar" on and a device readable: two compact stacked
/// lines instead — laptop/iphone glyphs so the two percentages aren't ambiguous.
struct MenuBarLabel: View {
    @ObservedObject var reader: BatteryReader
    @ObservedObject var iosReader: IOSDeviceReader
    @AppStorage("showMenuBarPercent") private var showMacPercent = true
    @AppStorage("showIPhoneMenuBar") private var showIPhoneMenuBar = false

    private var iosDevice: IOSDeviceInfo? {
        guard showIPhoneMenuBar,
              let device = iosReader.devices.first,
              device.chargePercent != nil else { return nil }
        return device
    }

    var body: some View {
        let macPct = Int(reader.info.chargePercent.rounded())

        if let ios = iosDevice, let iosCp = ios.chargePercent {
            // Both devices, baked into one image — no HStack for the menu bar to reverse.
            Image(nsImage: dualMenuBarImage(macPct: macPct,
                                            macCharging: reader.info.isCharging,
                                            iosPct: Int(iosCp.rounded()),
                                            iosCharging: ios.isCharging))
        } else {
            // Number lives inside the battery, so there's just one element — no HStack
            // ordering for the menu bar to reverse.
            BatteryGlyph(level: reader.info.chargePercent / 100,
                         charging: reader.info.isCharging,
                         percent: showMacPercent ? macPct : nil)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the Dock icon when running as a bare binary (the .app bundle uses LSUIElement)
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct BatteryBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var reader = BatteryReader()
    @StateObject private var iosReader = IOSDeviceReader()

    var body: some Scene {
        MenuBarExtra {
            BatteryDetailView(reader: reader, iosReader: iosReader)
        } label: {
            MenuBarLabel(reader: reader, iosReader: iosReader)
        }
        .menuBarExtraStyle(.window)
    }
}
