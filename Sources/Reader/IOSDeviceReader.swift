// IOSDeviceReader.swift — reads iPhone/iPad battery health over USB by shelling out to
// libimobiledevice (idevice_id / ideviceinfo / idevicediagnostics), same approach as
// cocobat.py --ios. Command-line plumbing (locating tools, running with a timeout) lives in
// DeviceTool.

import Foundation
import Combine

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

    private func infoValue(_ path: String, udid: String, key: String) -> String? {
        guard let data = DeviceTool.run(path, ["-u", udid, "-k", key]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Lists UDIDs, retrying a few times since the USB connection (usbmux) can drop for a few
    /// seconds, especially when the device is locked or another app is holding the lockdown session.
    private func listUDIDs(_ path: String) -> [String] {
        for attempt in 0..<5 {
            if let data = DeviceTool.run(path, ["-l"]),
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
            if let raw = DeviceTool.run(path, ["-u", udid, "ioregentry", "AppleSmartBattery"]),
               let plist = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil) as? [String: Any],
               let reg = plist["IORegistry"] as? [String: Any] {
                return reg
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.3) }
        }
        return nil
    }

    private func doRefresh() {
        guard let ideviceIdPath = DeviceTool.path("idevice_id"),
              let ideviceInfoPath = DeviceTool.path("ideviceinfo"),
              let diagnosticsPath = DeviceTool.path("idevicediagnostics") else {
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
