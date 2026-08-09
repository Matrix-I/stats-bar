// BluetoothGATT.swift — reads Bluetooth LE device battery over the GATT Battery Service
// (0x180F / characteristic 0x2A19) via CoreBluetooth.
//
// Why this exists: BLE accessories — notably Logitech mice like the MX Anywhere 3 — publish their
// battery ONLY through GATT. `system_profiler SPBluetoothDataType` reports nothing for them, and the
// private IOBluetoothDevice `batteryPercent*` properties read 0 for BLE devices (they only work for
// classic Bluetooth). Connecting to the peripheral and reading 0x2A19 is the only route that
// returns a real value (verified: MX Anywhere 3 → 95%). This is the mechanism Stats.app uses.
//
// That "they only work for classic Bluetooth" was written here as the reason to stop looking, and it
// was the lead: a Bluetooth CLASSIC headset can be read, just not from either source this file knew
// about. AccessoryPowerSource now covers those, and covers these too — it reports the same 90% for
// the MX Anywhere in 0.09 ms with no connection at all. This file is kept because that has been
// measured on three devices and not on earbuds, and CLAUDE.md asks for behaviour to be proved
// preserved rather than assumed; a GATT-only accessory would go dark the day it is deleted on faith.
//
// It keeps a CBCentralManager alive for the app's lifetime, connects to the already-system-connected
// peripherals that expose the Battery Service, reads the level, subscribes for live updates, and
// re-reads on demand. Requires NSBluetoothAlwaysUsageDescription (see build_app.sh) and the user
// granting Bluetooth permission; while unauthorised / powered off it simply stays empty.
//
// Join key is the device NAME: a BLE peripheral's identifier is a per-host UUID that does not map to
// the BD_ADDR system_profiler prints, so name is what correlates a GATT reading to a device row —
// the same correlation Stats makes.

import Foundation
import CoreBluetooth

final class BluetoothGATT: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// Latest battery percentage keyed by trimmed peripheral name. Main-thread only.
    private(set) var levelsByName: [String: Int] = [:]
    /// Invoked on the main thread whenever a level appears or changes, so the reader can republish.
    var onUpdate: (() -> Void)?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]        // retained so delegate callbacks fire
    private var batteryChars: [UUID: CBCharacteristic] = [:]   // cached for cheap re-reads

    /// Peripherals we have started a first read on and not yet heard back from, one way or the
    /// other. Only the FIRST read counts: a re-read of a characteristic we already have a value for
    /// leaves the old level on screen, so it is not a state anyone is waiting on.
    ///
    /// It has a deadline because `CBCentralManager.connect` has none: it retries indefinitely and
    /// delivers no "still trying" callback, so a peripheral that is listed by
    /// retrieveConnectedPeripherals and never completes a GATT connection would stay in here for the
    /// life of the process. `settled` is false while anything is outstanding, and `settled` is what
    /// tells every OTHER device's row to stop showing the pending ellipsis and admit it has no
    /// battery — so one unreachable mouse hung the entire list, permanently. That is the same symptom
    /// the two bugs already fixed in this file produced, arrived at a third way.
    ///
    /// Five seconds, which is BluetoothReader's poll cadence: a first read still outstanding a whole
    /// polling interval after it began has already missed the refresh that would have carried it.
    /// Expiring does NOT cancel the connection — see PendingFirstReads.deadline for why that
    /// asymmetry is what makes the exact number uncritical.
    private var awaitingFirstRead = PendingFirstReads<UUID>(deadline: 5)

    /// Whether this source has finished having its say, so a device still without a level can be
    /// called batteryless rather than pending. Not merely `levelsByName.isEmpty` — that is true both
    /// before the first read and on a machine with no BLE accessory at all.
    var settled: Bool {
        guard let central else { return false }
        switch central.state {
        // CoreBluetooth has not reported in yet; asking now tells us nothing. `init` publishes long
        // before this resolves, which is why the very first popover open used to show a dash for a
        // mouse that was about to report 90%.
        case .unknown, .resetting: return false
        case .poweredOn: return awaitingFirstRead.isSettled(now: Date())
        // Off, unauthorised or unsupported: this source will never answer, and saying so is the
        // truthful outcome rather than leaving every row pending forever.
        default: return true
        }
    }

    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")

    override init() {
        super.init()
        // Deliver every callback on the main queue; that's where levelsByName lives and where the
        // reader publishes, so no cross-thread access. Creating the manager triggers the one-time
        // Bluetooth permission prompt.
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Pick up newly connected battery-reporting peripherals and refresh the level of ones already
    /// connected. Safe to call often; a no-op until the central is powered on and authorised.
    func refresh() {
        guard central?.state == .poweredOn else { return }
        // Sweep before enumerating, so a peripheral that has overrun its deadline stops holding the
        // rows on the ellipsis at the same tick the next attempt is considered. The connection itself
        // is left running: nothing is paid for leaving it pending, and if CoreBluetooth does finally
        // connect, the ordinary delegate chain still discovers the characteristic and publishes the
        // level. The peripheral also stays in `peripherals`, so the branch below does not re-issue a
        // connect that is already outstanding and put the rows straight back into pending.
        if awaitingFirstRead.expire(now: Date()) { onUpdate?() }
        for peripheral in central.retrieveConnectedPeripherals(withServices: [batteryService]) {
            if let existing = peripherals[peripheral.identifier] {
                if let ch = batteryChars[existing.identifier] { existing.readValue(for: ch) }
            } else {
                peripherals[peripheral.identifier] = peripheral
                peripheral.delegate = self
                awaitingFirstRead.begin(peripheral.identifier, at: Date())
                central.connect(peripheral, options: nil)
            }
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard manager.state == .poweredOn else {
            // Leaving .poweredOn (adapter switched off, reset, or deauthorised) invalidates every
            // peripheral and its connection, but CoreBluetooth does NOT deliver a per-device
            // didDisconnectPeripheral for that transition — so our retained CBPeripheral /
            // CBCharacteristic objects silently go stale. Drop them all so the next .poweredOn takes
            // the reconnect path in refresh() instead of re-reading a dead characteristic (which never
            // calls back, freezing the level forever). Clear the published levels too, so a powered-off
            // adapter shows no battery rather than a frozen last reading.
            peripherals.removeAll()
            batteryChars.removeAll()
            // Nothing is in flight any more, and `settled` reports true for these states anyway.
            awaitingFirstRead.removeAll()
            levelsByName.removeAll()
            // Published unconditionally, unlike the old "only if a level was lost" test: `settled`
            // has just become true for these states, and a row with no level has to stop saying "…"
            // and admit there is nothing to wait for.
            onUpdate?()
            return
        }
        refresh()
        // Likewise on the way in. This is the transition out of .unknown, which is the state the
        // very first publish always happens in, and refresh() has just decided whether anything is
        // pending — so this is the moment the rows can stop guessing.
        onUpdate?()
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryService])
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        peripherals[peripheral.identifier] = nil
        finishFirstRead(peripheral)
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        peripherals[peripheral.identifier] = nil
        batteryChars[peripheral.identifier] = nil
        finishFirstRead(peripheral)
        // Drop the stale reading so a disconnected device doesn't show a frozen level.
        let name = (peripheral.name ?? "").trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, levelsByName[name] != nil {
            levelsByName[name] = nil
            onUpdate?()
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = (peripheral.services ?? []).filter { $0.uuid == batteryService }
        // Every exit from the round trip has to clear the pending flag, or one peripheral that
        // errors or turns out to have no Battery Service leaves every row reading "…" forever.
        guard error == nil, !services.isEmpty else { return finishFirstRead(peripheral) }
        for service in services { peripheral.discoverCharacteristics([batteryLevel], for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let found = (service.characteristics ?? []).filter { $0.uuid == batteryLevel }
        guard error == nil, !found.isEmpty else { return finishFirstRead(peripheral) }
        for ch in found {
            batteryChars[peripheral.identifier] = ch
            peripheral.readValue(for: ch)
            if ch.properties.contains(.notify) { peripheral.setNotifyValue(true, for: ch) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == batteryLevel else { return }
        // Answered, whatever the answer: a read that came back empty or failed is still this
        // source's final word on the device, not a reason to keep the row pending.
        finishFirstRead(peripheral)
        guard let byte = characteristic.value?.first else { return }
        let name = (peripheral.name ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let percent = min(100, Int(byte))
        if levelsByName[name] != percent {
            levelsByName[name] = percent
            onUpdate?()
        }
    }

    /// Mark a peripheral as no longer awaited, and republish if that was the last one — otherwise a
    /// row would sit on "…" until some later event happened to trigger a publish.
    private func finishFirstRead(_ peripheral: CBPeripheral) {
        if awaitingFirstRead.finish(peripheral.identifier) { onUpdate?() }
    }
}
