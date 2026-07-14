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

    // Live SMC power rails (~1 Hz — unlike the AppleSmartBattery gauge above, which only
    // refreshes every ~30–60 s). nil when the machine doesn't expose that key / SMC is unavailable.
    var smcSystemTotalW: Double? = nil   // PSTR — whole-system power
    var smcDCInW: Double? = nil          // PDTR — power drawn from the charger
    var smcBrightnessW: Double? = nil    // PDBR — display backlight
    var smcThunderboltLW: Double? = nil  // PU1R
    var smcThunderboltRW: Double? = nil  // PU2R
    var smcPPBRW: Double? = nil          // PPBR

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
    private let smc = SMC()

    private static let idleInterval: TimeInterval = 1    // refresh every second, even for the menu-bar glyph alone
    private static let activeInterval: TimeInterval = 1  // live readout while the detail panel is open

    init() {
        refresh()
        schedule(Self.idleInterval)
    }

    private func schedule(_ seconds: TimeInterval) {
        guard seconds != interval else { return }
        interval = seconds
        timer?.invalidate()
        // Register in .common modes, not the implicit .default of scheduledTimer: while the
        // menu-bar popover is up the run loop can sit in event-tracking mode, where a
        // .default-only timer never fires — that's what makes the "live" readout freeze.
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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

        // Live SMC power rails (these actually move every second — see the header note on BatteryInfo).
        i.smcSystemTotalW  = smc.readFloat("PSTR")
        i.smcDCInW         = smc.readFloat("PDTR")
        i.smcBrightnessW   = smc.readFloat("PDBR")
        i.smcThunderboltLW = smc.readFloat("PU1R")
        i.smcThunderboltRW = smc.readFloat("PU2R")
        i.smcPPBRW         = smc.readFloat("PPBR")

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

// MARK: - SMC reader (live power-rail sensors)

/// Reads power-rail sensors straight from the AppleSMC user client — the same source iStat Menus'
/// POWER section uses, and (unlike the AppleSmartBattery gauge) it refreshes at roughly 1 Hz.
/// No root or entitlement needed. Every rail is a `flt ` (little-endian Float32) key in Watts.
/// SMC key names are chip-specific, so `readFloat` returns nil for any key this Mac doesn't expose.
final class SMC {
    private var conn: io_connect_t = 0
    private(set) var isAvailable = false

    // The kernel expects an 80-byte SMCParamStruct. Swift lays the nested structs out to match ONLY
    // if `KeyInfo` is padded to its full 12-byte stride — without pad0…2, Swift packs `result`
    // right after the 9 used bytes and the whole tail shifts, giving a 76-byte struct the SMC rejects.
    private struct Version { var major: UInt8=0; var minor: UInt8=0; var build: UInt8=0; var reserved: UInt8=0; var release: UInt16=0 }
    private struct PLimit  { var version: UInt16=0; var length: UInt16=0; var cpuPLimit: UInt32=0; var gpuPLimit: UInt32=0; var memPLimit: UInt32=0 }
    private struct KeyInfo { var dataSize: UInt32=0; var dataType: UInt32=0; var dataAttributes: UInt8=0; var pad0: UInt8=0; var pad1: UInt8=0; var pad2: UInt8=0 }
    private struct Param {
        var key: UInt32 = 0
        var vers = Version()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) =
                   (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private static let readBytes: UInt8 = 5     // SMC_CMD_READ_BYTES
    private static let readKeyInfo: UInt8 = 9   // SMC_CMD_READ_KEYINFO
    private static let kSMCHandleYPCEvent: UInt32 = 2

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(svc) }
        isAvailable = IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS
    }

    deinit { if isAvailable { IOServiceClose(conn) } }

    private func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for c in s.utf8 { r = (r << 8) | UInt32(c) }
        return r
    }

    private func call(_ input: inout Param, _ output: inout Param) -> Bool {
        let inSize = MemoryLayout<Param>.stride
        var outSize = MemoryLayout<Param>.stride
        return IOConnectCallStructMethod(conn, Self.kSMCHandleYPCEvent, &input, inSize, &output, &outSize) == KERN_SUCCESS
    }

    /// Returns the value of a 32-bit-float SMC key in its native unit (Watts for the P* rails),
    /// or nil if SMC is unavailable, the key is missing, or it isn't a `flt ` key.
    func readFloat(_ key: String) -> Double? {
        guard isAvailable else { return nil }
        let k = fourCC(key)

        var infoIn = Param(); infoIn.key = k; infoIn.data8 = Self.readKeyInfo
        var infoOut = Param()
        guard call(&infoIn, &infoOut), infoOut.result == 0,
              infoOut.keyInfo.dataType == fourCC("flt "), infoOut.keyInfo.dataSize == 4 else { return nil }

        var readIn = Param(); readIn.key = k; readIn.keyInfo = infoOut.keyInfo; readIn.data8 = Self.readBytes
        var readOut = Param()
        guard call(&readIn, &readOut), readOut.result == 0 else { return nil }

        let raw = UInt32(readOut.bytes.0)
                | (UInt32(readOut.bytes.1) << 8)
                | (UInt32(readOut.bytes.2) << 16)
                | (UInt32(readOut.bytes.3) << 24)
        return Double(Float(bitPattern: raw))
    }
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
    var amperageA: Double?         // negative = discharging, positive = charging
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
    var watts: Double? {
        guard let v = voltageV, let a = amperageA else { return nil }
        return v * a
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
    /// How long to keep showing the last reading after reads stop succeeding, before the device
    /// disappears. Short when it drops out of USB enumeration entirely (usually a real unplug),
    /// longer when it's still enumerated but the battery read fails (e.g. locked / another app holds
    /// the lockdown session, which tends to recover on its own).
    private static let staleGraceGone: TimeInterval = 5
    private static let staleGraceUnreadable: TimeInterval = 30
    private static let toolTimeout: TimeInterval = 4   // kill a libimobiledevice tool that overruns this

    private static let searchDirs = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"]

    init() {
        refresh()
        // MenuBarExtra(.window) builds the view once and just shows/hides it afterward — .onAppear
        // doesn't refire on every menu open, so a dedicated timer is needed to pick up plug/unplug events.
        // Poll every second like the Mac reader. Each tick shells out to libimobiledevice (a few
        // subprocesses + USB round-trips), but refresh()'s isBusy guard drops any tick that lands
        // while the previous read is still running, so a slow cycle just lowers the effective rate.
        // .common mode keeps it firing while the menu-bar popover is up (event-tracking run-loop mode).
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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

        // Bail out if the tool overruns: unplugging the device mid-read can leave
        // idevicediagnostics/ideviceinfo blocked indefinitely, which would otherwise hang this
        // reader thread (waitUntilExit never returns), wedge isBusy at true, and freeze the whole
        // iOS section until relaunch.
        if group.wait(timeout: .now() + Self.toolTimeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 1)   // let the pipe readers hit EOF and unwind
            return nil
        }
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
            if let a = signedIntOrNil(reg["Amperage"]) { dev.amperageA = Double(a) / 1000.0 }
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
            let sinceGood = self.lastGoodAt.map { now.timeIntervalSince($0) } ?? .infinity

            // Empty enumeration → device is off the USB bus. Ride out a brief blip, then let it go:
            // a deliberate unplug should clear within a few seconds, not linger.
            if fresh.isEmpty {
                if sinceGood < Self.staleGraceGone, !self.lastGood.isEmpty {
                    self.devices = self.lastGood.map { var d = $0; d.isStale = true; return d }
                    self.statusMessage = nil
                } else {
                    self.devices = []
                    self.statusMessage = status
                        ?? "No iPhone/iPad found over USB.\nPlug in the cable, unlock the device, tap Trust."
                }
                return
            }

            // Enumeration succeeded: a device whose battery read failed briefly reuses the last good
            // data; genuinely fresh reads are shown as-is.
            var merged: [IOSDeviceInfo] = []
            var freshGood: [IOSDeviceInfo] = []
            for dev in fresh {
                if dev.errorMessage != nil, sinceGood < Self.staleGraceUnreadable,
                   let prev = self.lastGood.first(where: { $0.id == dev.id }) {
                    var s = prev; s.isStale = true
                    merged.append(s)
                } else {
                    merged.append(dev)
                    if dev.errorMessage == nil { freshGood.append(dev) }
                }
            }
            self.devices = merged
            self.statusMessage = nil

            // Only genuinely fresh reads refresh the grace window. Reused stale entries also carry
            // errorMessage == nil, so counting them would keep resetting the timer and the device
            // would never time out while it stays enumerated-but-unreadable.
            if !freshGood.isEmpty {
                self.lastGood = freshGood
                self.lastGoodAt = now
            }
        }
    }
}

// MARK: - Android device model + reader

/// Android exposes far less over USB than libimobiledevice does for iOS: `dumpsys battery` has no
/// cycle count or design/full-charge capacity on stock Android, so those fields simply don't exist
/// here — the UI only shows what's actually available (charge %, voltage, temperature, health).
struct AndroidDeviceInfo: Identifiable {
    let id: String                // adb serial
    var name = ""
    var manufacturer = ""
    var androidVersion = ""
    var levelPercent: Int?
    var voltageV: Double?
    var temperatureC: Double?
    var technology = ""
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    var healthText: String?
    // From `dumpsys batterystats` (not the fast per-second `dumpsys battery`): Android's own
    // coulomb-counter-learned full-charge estimate and the OEM-declared rated/design capacity.
    // Fetched once per connection and cached — see AndroidDeviceReader.readCapacity.
    var maxCapacity: Int?          // mAh — "Estimated battery capacity" (health-adjusted)
    var designCapacity: Int?       // mAh — "Capacity:" under "Estimated power use" (rated by OEM)
    // Android has no exposed instantaneous current (no `current_now` without root, no health HAL
    // debug dump, and "Charge counter" barely changes between 1s polls) — so unlike iOS/Mac's
    // "Charging with" (live V×I), this is the charger/port's negotiated ceiling, not a live reading.
    var maxChargingWatts: Double?
    var serial = ""
    var errorMessage: String?
    var isStale = false
    var capturedAt: Date?

    var healthPercent: Double? {
        guard let max = maxCapacity, max > 0, let design = designCapacity, design > 0 else { return nil }
        return Double(max) / Double(design) * 100
    }
}

private func androidStatusText(_ code: Int?) -> (charging: Bool, full: Bool) {
    (code == 2, code == 5)
}

private func androidHealthText(_ code: Int?) -> String? {
    switch code {
    case 2: return "Good"
    case 3: return "Overheat"
    case 4: return "Dead"
    case 5: return "Over voltage"
    case 6: return "Unspecified failure"
    case 7: return "Cold"
    default: return nil   // 1 (unknown) or missing — not worth showing
    }
}

final class AndroidDeviceReader: ObservableObject {
    @Published var devices: [AndroidDeviceInfo] = []
    @Published var toolsMissing = false
    @Published var statusMessage: String?

    private var isBusy = false
    private var timer: Timer?

    private var lastGood: [AndroidDeviceInfo] = []
    private var lastGoodAt: Date?
    private static let staleGraceGone: TimeInterval = 5
    private static let staleGraceUnreadable: TimeInterval = 30
    private static let toolTimeout: TimeInterval = 4

    /// `dumpsys batterystats` (unlike the fast per-second `dumpsys battery`) can dump several MB of
    /// history and take a while, so it's only fetched once per connected serial and cached — not
    /// worth re-running every second for numbers that barely change. Only touched from doRefresh(),
    /// which refresh()'s isBusy guard ensures never runs concurrently with itself.
    private var capacityCache: [String: (max: Int?, design: Int?)] = [:]
    private var capacityLastAttempt: [String: Date] = [:]
    private static let capacityRetryInterval: TimeInterval = 30

    private static let searchDirs = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"]

    init() {
        refresh()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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

    /// Same concurrent-pipe-drain + timeout approach as the iOS reader's `run` — adb can hang on a
    /// device that's mid-unplug, and this must never wedge `isBusy`.
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

        if group.wait(timeout: .now() + Self.toolTimeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 1)
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? outData : nil
    }

    /// Parses `adb devices -l` into (serial, state) pairs — state is "device", "unauthorized", or
    /// "offline". Unlike idevice_id, adb only needs one call (no separate USB-enumeration retry loop).
    private func listDevices(_ path: String) -> [(serial: String, state: String)] {
        guard let data = run(path, ["devices", "-l"]),
              let s = String(data: data, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0 != "List of devices attached" }
            .compactMap { line in
                let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { return nil }
                return (serial: String(parts[0]), state: String(parts[1]).split(separator: " ").first.map(String.init) ?? "")
            }
    }

    private func getprop(_ path: String, serial: String, key: String) -> String? {
        guard let data = run(path, ["-s", serial, "shell", "getprop", key]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `dumpsys battery` prints plain "  Key: value" lines — no plist/JSON on Android.
    private func readBattery(_ path: String, serial: String) -> [String: String]? {
        guard let data = run(path, ["-s", serial, "shell", "dumpsys", "battery"]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        for line in s.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            out[key] = value
        }
        return out.isEmpty ? nil : out
    }

    /// `dumpsys batterystats` has no plist/JSON either, just free-form text. Two lines matter:
    ///   "Estimated battery capacity: 3932 mAh"       — Android's coulomb-counter learned full charge
    ///   "Capacity: 4000, Computed drain: ..., ..."   — OEM-declared rated/design capacity, under the
    ///                                                   "Estimated power use (mAh):" section
    /// Confirmed against a real device (Redmi Note 7): 3932 / 4000 mAh, matching its published spec.
    private func readCapacity(_ path: String, serial: String) -> (max: Int?, design: Int?) {
        guard let data = run(path, ["-s", serial, "shell", "dumpsys", "batterystats"]),
              let s = String(data: data, encoding: .utf8) else { return (nil, nil) }
        var maxCap: Int?
        var designCap: Int?
        for line in s.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if maxCap == nil, t.hasPrefix("Estimated battery capacity:") {
                let rest = t.dropFirst("Estimated battery capacity:".count)
                    .replacingOccurrences(of: "mAh", with: "")
                maxCap = Int(rest.trimmingCharacters(in: .whitespaces))
            } else if designCap == nil, t.hasPrefix("Capacity:") {
                let rest = t.dropFirst("Capacity:".count)
                if let comma = rest.firstIndex(of: ",") {
                    designCap = Int(rest[rest.startIndex..<comma].trimmingCharacters(in: .whitespaces))
                }
            }
            if maxCap != nil && designCap != nil { break }
        }
        return (maxCap, designCap)
    }

    private func doRefresh() {
        guard let adbPath = toolPath("adb") else {
            publish(devices: [], toolsMissing: true, status: nil)
            return
        }

        let listed = listDevices(adbPath)
        guard !listed.isEmpty else {
            publish(devices: [], toolsMissing: false,
                    status: "No Android device found over USB.\nPlug in the cable and enable USB debugging.")
            return
        }

        var results: [AndroidDeviceInfo] = []
        for entry in listed {
            var dev = AndroidDeviceInfo(id: entry.serial)
            dev.serial = entry.serial

            guard entry.state == "device" else {
                dev.errorMessage = entry.state == "unauthorized"
                    ? "Unlock the phone and tap Allow on the \"Allow USB debugging?\" prompt."
                    : "Device is \(entry.state) — reconnect the cable."
                results.append(dev)
                continue
            }

            dev.name = getprop(adbPath, serial: entry.serial, key: "ro.product.model") ?? entry.serial
            dev.manufacturer = getprop(adbPath, serial: entry.serial, key: "ro.product.manufacturer") ?? ""
            dev.androidVersion = getprop(adbPath, serial: entry.serial, key: "ro.build.version.release") ?? ""

            guard let bat = readBattery(adbPath, serial: entry.serial) else {
                dev.errorMessage = "Couldn't read battery status — reconnect and unlock the phone."
                results.append(dev)
                continue
            }

            let level = Int(bat["level"] ?? "")
            let scale = Int(bat["scale"] ?? "") ?? 100
            if let level, scale > 0 { dev.levelPercent = level * 100 / scale }
            if let v = Int(bat["voltage"] ?? "") { dev.voltageV = Double(v) / 1000.0 }
            if let t = Int(bat["temperature"] ?? "") { dev.temperatureC = Double(t) / 10.0 }
            dev.technology = bat["technology"] ?? ""
            let statusCode = Int(bat["status"] ?? "")
            let (charging, full) = androidStatusText(statusCode)
            dev.isCharging = charging
            dev.fullyCharged = full
            dev.healthText = androidHealthText(Int(bat["health"] ?? ""))
            if let mc = Int(bat["Max charging current"] ?? ""), let mv = Int(bat["Max charging voltage"] ?? ""),
               mc > 0, mv > 0 {
                dev.maxChargingWatts = (Double(mc) / 1_000_000.0) * (Double(mv) / 1_000_000.0)
            }
            dev.externalConnected = ["AC powered", "USB powered", "Wireless powered"]
                .contains { bat[$0] == "true" }
            dev.capturedAt = Date()

            if let cached = capacityCache[entry.serial] {
                dev.maxCapacity = cached.max
                dev.designCapacity = cached.design
            } else {
                let lastAttempt = capacityLastAttempt[entry.serial]
                if lastAttempt == nil || Date().timeIntervalSince(lastAttempt!) > Self.capacityRetryInterval {
                    capacityLastAttempt[entry.serial] = Date()
                    let cap = readCapacity(adbPath, serial: entry.serial)
                    if cap.max != nil || cap.design != nil {
                        capacityCache[entry.serial] = cap
                        dev.maxCapacity = cap.max
                        dev.designCapacity = cap.design
                    }
                }
            }

            results.append(dev)
        }

        publish(devices: results, toolsMissing: false, status: nil)
    }

    private func publish(devices fresh: [AndroidDeviceInfo], toolsMissing: Bool, status: String?) {
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
            let sinceGood = self.lastGoodAt.map { now.timeIntervalSince($0) } ?? .infinity

            if fresh.isEmpty {
                if sinceGood < Self.staleGraceGone, !self.lastGood.isEmpty {
                    self.devices = self.lastGood.map { var d = $0; d.isStale = true; return d }
                    self.statusMessage = nil
                } else {
                    self.devices = []
                    self.statusMessage = status
                        ?? "No Android device found over USB.\nPlug in the cable and enable USB debugging."
                }
                return
            }

            var merged: [AndroidDeviceInfo] = []
            var freshGood: [AndroidDeviceInfo] = []
            for dev in fresh {
                if dev.errorMessage != nil, sinceGood < Self.staleGraceUnreadable,
                   let prev = self.lastGood.first(where: { $0.id == dev.id }) {
                    var s = prev; s.isStale = true
                    merged.append(s)
                } else {
                    merged.append(dev)
                    if dev.errorMessage == nil { freshGood.append(dev) }
                }
            }
            self.devices = merged
            self.statusMessage = nil

            if !freshGood.isEmpty {
                self.lastGood = freshGood
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

    // --- Number-left style: the % is drawn as a label to the LEFT of the battery
    // glyph, and the glyph itself uses the proportional fill (same as the hidden-%
    // fill style). Total width = label + gap + battery body + terminal nub. ---
    if let percent {
        let text = "\(percent)%" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = text.size(withAttributes: attrs)
        let labelW = ceil(textSize.width)
        let gap: CGFloat = 3
        let bodyW: CGFloat = 21.4                 // battery body width (glyph only)
        let w = labelW + gap + bodyW + 3.6        // + terminal nub

        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            // Percentage label on the left, vertically centred.
            text.draw(at: NSPoint(x: 0, y: (h - textSize.height) / 2 + 0.3), withAttributes: attrs)

            // Battery glyph to the right of the label.
            let bx = labelW + gap
            let bodyRect = NSRect(x: bx + lw / 2, y: lw / 2, width: bodyW, height: h - lw)
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: bodyRect, xRadius: 3.4, yRadius: 3.4)
            outline.lineWidth = lw
            outline.stroke()

            let inner = bodyRect.insetBy(dx: lw + 0.7, dy: lw + 0.7)
            let fillW = max(1.5, inner.width * min(max(level, 0), 1))
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: fillW, height: inner.height),
                         xRadius: 1.6, yRadius: 1.6).fill()

            NSBezierPath(roundedRect: NSRect(x: bx + bodyW + 0.6, y: h / 2 - 2.4, width: 1.7, height: 4.8),
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
func dualMenuBarImage(macPct: Int, macCharging: Bool, phonePct: Int, phoneCharging: Bool,
                       phoneSymbol: String, showPercent: Bool) -> NSImage {
    let h: CGFloat = 13, symH: CGFloat = 10
    let macBat = batteryMenuBarImage(level: Double(macPct) / 100, charging: macCharging, percent: showPercent ? macPct : nil)
    let phoneBat = batteryMenuBarImage(level: Double(phonePct) / 100, charging: phoneCharging, percent: showPercent ? phonePct : nil)
    func symbol(_ name: String) -> NSImage? {
        guard let s = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        s.isTemplate = true
        return s
    }
    let laptop = symbol("laptopcomputer"), phone = symbol(phoneSymbol)
    func widthOf(_ img: NSImage?) -> CGFloat {
        guard let img else { return 0 }
        return symH * (img.size.width / max(img.size.height, 1))
    }
    let laptopW = widthOf(laptop), phoneW = widthOf(phone)
    let gap: CGFloat = 2.5, bigGap: CGFloat = 6
    let total = laptopW + gap + macBat.size.width + bigGap + phoneW + gap + phoneBat.size.width

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
        phoneBat.draw(in: NSRect(x: x, y: 0, width: phoneBat.size.width, height: h),
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
                if let max = device.maxCapacity {
                    InfoRow(label: "Full charge capacity", value: "\(max) mAh")
                }
                if let design = device.designCapacity {
                    InfoRow(label: "Design capacity", value: "\(design) mAh")
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
                if device.isCharging, let w = device.watts, w > 0.05 {
                    InfoRow(label: "Charging with", value: String(format: "%.1f W", w))
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

struct AndroidDeviceRow: View {
    let device: AndroidDeviceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(device.name).font(.caption).fontWeight(.semibold).lineLimit(1)
                Spacer()
                let sub = [device.manufacturer.isEmpty ? nil : device.manufacturer,
                           device.androidVersion.isEmpty ? nil : "Android \(device.androidVersion)"]
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
                Text(err).font(.caption2).foregroundStyle(.orange)
            } else {
                if let level = device.levelPercent {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Charge").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(level)%").font(.caption).fontWeight(.medium).monospacedDigit()
                    }
                    BarView(pct: Double(level), color: .blue)
                }
                if let hp = device.healthPercent {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Health (vs design)").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f%%", hp))
                            .font(.caption).fontWeight(.medium).monospacedDigit()
                            .foregroundStyle(healthColor(hp))
                    }
                    BarView(pct: hp, color: healthColor(hp))
                }
                if let max = device.maxCapacity {
                    InfoRow(label: "Full charge capacity", value: "\(max) mAh")
                }
                if let design = device.designCapacity {
                    InfoRow(label: "Design capacity", value: "\(design) mAh")
                }
                if let health = device.healthText {
                    InfoRow(label: "Health status", value: health)
                }
                if let t = device.temperatureC {
                    InfoRow(label: "Temperature", value: String(format: "%.1f °C", t))
                }
                if let v = device.voltageV {
                    InfoRow(label: "Voltage", value: String(format: "%.2f V", v))
                }
                if !device.technology.isEmpty {
                    InfoRow(label: "Technology", value: device.technology)
                }
                if device.isCharging, let w = device.maxChargingWatts {
                    InfoRow(label: "Max charging power", value: String(format: "%.1f W", w))
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

struct AndroidDevicesSection: View {
    @ObservedObject var reader: AndroidDeviceReader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🤖 Android (USB)").font(.caption).foregroundStyle(.secondary)

            if reader.toolsMissing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Missing adb.").font(.caption2).foregroundStyle(.orange)
                    Text("brew install --cask android-platform-tools")
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
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(reader.devices) { device in
                        AndroidDeviceRow(device: device)
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
    @ObservedObject var androidReader: AndroidDeviceReader
    @AppStorage("showMenuBarPercent") private var showMenuBarPercent = true
    @AppStorage("showIPhoneMenuBar") private var showIPhoneMenuBar = false
    @AppStorage("showAndroidMenuBar") private var showAndroidMenuBar = false

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
                InfoRow(label: "Full charge capacity", value: "\(i.maxCapacity) mAh")
                InfoRow(label: "Design capacity", value: "\(i.designCapacity) mAh")
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

            // ⚡ Live power rails from the SMC — these tick every second, unlike the
            // battery-gauge values above (which the OS only refreshes every ~30–60 s).
            if i.smcSystemTotalW != nil || i.smcDCInW != nil {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("⚡ Power (live)").font(.caption).foregroundStyle(.secondary)
                    if let v = i.smcSystemTotalW { InfoRow(label: "System Total", value: String(format: "%.2f W", v)) }
                    if let v = i.smcDCInW, v > 0.05 { InfoRow(label: "DC In", value: String(format: "%.2f W", v)) }
                    if let v = i.smcBrightnessW, v > 0.05 { InfoRow(label: "Display", value: String(format: "%.2f W", v)) }
                    if let v = i.smcThunderboltLW { InfoRow(label: "Thunderbolt L", value: String(format: "%.2f W", v)) }
                    if let v = i.smcThunderboltRW { InfoRow(label: "Thunderbolt R", value: String(format: "%.2f W", v)) }
                    if let v = i.smcPPBRW { InfoRow(label: "PPBR", value: String(format: "%.2f W", v)) }
                }
            }

            Divider()

            IOSDevicesSection(reader: iosReader)
                .onAppear { iosReader.refresh() }

            Divider()

            AndroidDevicesSection(reader: androidReader)
                .onAppear { androidReader.refresh() }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show % in menu bar", isOn: $showMenuBarPercent)
                Toggle("Show iPhone in menu bar", isOn: $showIPhoneMenuBar)
                Toggle("Show Android in menu bar", isOn: $showAndroidMenuBar)
            }
            .font(.caption)
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            HStack {
                Button("Refresh") {
                    reader.refresh()
                    iosReader.refresh()
                    androidReader.refresh()
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
            if open {
                iosReader.refresh()      // one immediate read on open; it stays on its slow cadence
                androidReader.refresh()
            }
        })
    }

    private func powerText(_ i: BatteryInfo) -> String {
        // Plugged in: show DC in (power drawn from the charger). On battery: show discharge power.
        // Prefer the SMC rails — they refresh ~1 Hz, so this row actually moves; the AdapterPower /
        // voltage×amperage fallbacks come from the battery gauge and only update every ~30–60 s.
        if i.externalConnected {
            if let dc = i.smcDCInW, dc > 0.05 {
                return String(format: "%.2f W (DC in)", dc)
            }
            if i.adapterPower > 0.05 {
                return String(format: "%.1f W (DC in)", i.adapterPower)
            }
            // Fallback for machines that don't expose AdapterPower (e.g. Intel): power flowing into the battery
            let charge = i.watts
            return charge > 0.05 ? String(format: "%.1f W (charging battery)", charge) : "—"
        }
        if let sys = i.smcSystemTotalW, sys > 0.05 {
            return String(format: "%.2f W (system)", sys)
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
/// With "Show iPhone/Android in menu bar" on and a device readable: two compact stacked
/// lines instead — laptop/phone glyphs so the two percentages aren't ambiguous. Only one
/// mobile device is ever shown at a time (iPhone takes priority when both are connected),
/// to keep the menu bar from growing a third glyph.
struct MenuBarLabel: View {
    @ObservedObject var reader: BatteryReader
    @ObservedObject var iosReader: IOSDeviceReader
    @ObservedObject var androidReader: AndroidDeviceReader
    @AppStorage("showMenuBarPercent") private var showMacPercent = true
    @AppStorage("showIPhoneMenuBar") private var showIPhoneMenuBar = false
    @AppStorage("showAndroidMenuBar") private var showAndroidMenuBar = false

    private var iosDevice: IOSDeviceInfo? {
        guard showIPhoneMenuBar,
              let device = iosReader.devices.first,
              device.chargePercent != nil else { return nil }
        return device
    }

    private var androidDevice: AndroidDeviceInfo? {
        guard showAndroidMenuBar,
              let device = androidReader.devices.first,
              device.levelPercent != nil else { return nil }
        return device
    }

    var body: some View {
        let macPct = Int(reader.info.chargePercent.rounded())

        if let ios = iosDevice, let iosCp = ios.chargePercent {
            // Both devices, baked into one image — no HStack for the menu bar to reverse.
            Image(nsImage: dualMenuBarImage(macPct: macPct,
                                            macCharging: reader.info.isCharging,
                                            phonePct: Int(iosCp.rounded()),
                                            phoneCharging: ios.isCharging,
                                            phoneSymbol: "iphone",
                                            showPercent: showMacPercent))
        } else if let android = androidDevice, let level = android.levelPercent {
            Image(nsImage: dualMenuBarImage(macPct: macPct,
                                            macCharging: reader.info.isCharging,
                                            phonePct: level,
                                            phoneCharging: android.isCharging,
                                            phoneSymbol: "candybarphone",
                                            showPercent: showMacPercent))
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
    @StateObject private var androidReader = AndroidDeviceReader()

    var body: some Scene {
        MenuBarExtra {
            BatteryDetailView(reader: reader, iosReader: iosReader, androidReader: androidReader)
        } label: {
            MenuBarLabel(reader: reader, iosReader: iosReader, androidReader: androidReader)
        }
        .menuBarExtraStyle(.window)
    }
}
