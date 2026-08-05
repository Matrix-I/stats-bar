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
        for peripheral in central.retrieveConnectedPeripherals(withServices: [batteryService]) {
            if let existing = peripherals[peripheral.identifier] {
                if let ch = batteryChars[existing.identifier] { existing.readValue(for: ch) }
            } else {
                peripherals[peripheral.identifier] = peripheral
                peripheral.delegate = self
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
            if !levelsByName.isEmpty {
                levelsByName.removeAll()
                onUpdate?()
            }
            return
        }
        refresh()
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryService])
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        peripherals[peripheral.identifier] = nil
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        peripherals[peripheral.identifier] = nil
        batteryChars[peripheral.identifier] = nil
        // Drop the stale reading so a disconnected device doesn't show a frozen level.
        let name = (peripheral.name ?? "").trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, levelsByName[name] != nil {
            levelsByName[name] = nil
            onUpdate?()
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == batteryService {
            peripheral.discoverCharacteristics([batteryLevel], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] where ch.uuid == batteryLevel {
            batteryChars[peripheral.identifier] = ch
            peripheral.readValue(for: ch)
            if ch.properties.contains(.notify) { peripheral.setNotifyValue(true, for: ch) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == batteryLevel, let byte = characteristic.value?.first else { return }
        let name = (peripheral.name ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let percent = min(100, Int(byte))
        if levelsByName[name] != percent {
            levelsByName[name] = percent
            onUpdate?()
        }
    }
}
