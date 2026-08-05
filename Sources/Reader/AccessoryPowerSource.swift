// AccessoryPowerSource.swift — the battery percentages macOS keeps for connected Bluetooth
// accessories, read from IOKit's power-source registry.
//
// This is the third and widest of the app's battery sources, and the only one that can see a
// Bluetooth CLASSIC device. Measured on a 16 GiB M1 Pro with a Sony WH-CH520 headset, a Logitech
// MX Anywhere 3 and a BLE keyboard connected:
//
//                          system_profiler   GATT   accessory power sources
//     MX Anywhere 3 (BLE)        -            90%            90
//     R65 5.0       (BLE)       100%           -            100
//     WH-CH520  (classic)        -             -             70    <- shown as "-" before this file
//
// The headset is why: it advertises HFP/AVRCP/A2DP and no BLE bit, so CoreBluetooth never enumerates
// it (retrieveConnectedPeripherals returns LE peripherals only) and SPBluetoothReporter reads a
// CBDevice field that its records simply do not carry. bluetoothd publishes the classic figure here
// instead, on a channel of its own — the same 70% Control Center shows.
//
// TWO TRAPS, both of which cost real time to find:
//
//  • It must be IOPSCopyPowerSourcesByType. The familiar IOPSCopyPowerSourcesInfo/List pair reports
//    only sources that could power the Mac — the internal battery and a UPS — so it answers "1
//    source" on a machine with three accessories attached and reads as proof that macOS knows
//    nothing. Two independent investigations of this bug reached exactly that wrong conclusion by
//    calling the wrong function inside the right API.
//  • The symbol is exported from IOKit.tbd but declared in no public header, so it is reached through
//    dlsym rather than linked. That is deliberate and not merely cautious: a direct reference to a
//    symbol a future macOS withdraws is a dyld failure at LAUNCH, which for an app that ships itself
//    through Sparkle means an update that simply never opens again. Through dlsym the same day costs
//    one em dash per accessory row.
//
// Nothing here needs a bundle, an entitlement, a TCC grant or a subprocess, and one call costs
// 0.09 ms against system_profiler's ~160 ms. (The private ObjC route to the same number —
// IOBluetoothDevice.batteryPercentSingle — needs all four: it SIGABRTs any process whose Info.plist
// has no NSBluetoothAlwaysUsageDescription, and attributes that check to the parent process.)

import Foundation
import IOKit.ps

enum AccessoryPowerSource {

    /// Every accessory battery macOS currently publishes. Empty when the symbol is gone, when the
    /// call fails, or when nothing is connected — all three are the same thing to a caller, which is
    /// "no reading", and none of them is an error worth surfacing.
    static func read() -> [AccessoryBattery] {
        guard let copy = copyByType,
              let raw = copy(accessorySourceType)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }

        return raw.compactMap { entry in
            // Filter on the record's own Type rather than trusting the argument: the type constant
            // is undocumented, so this stays correct even if a future macOS renumbers it and the
            // call starts returning a wider set.
            guard entry[kIOPSTypeKey as String] as? String == kIOPSAccessoryType else { return nil }

            let name = (entry[kIOPSNameKey as String] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }

            guard let current = int(entry[kIOPSCurrentCapacityKey as String]) else { return nil }
            // Absent Max Capacity means the record is already a percentage; every accessory record
            // observed reports 100 here.
            let maximum = int(entry[kIOPSMaxCapacityKey as String]) ?? 100
            guard let percent = AccessoryBattery.percent(current: current, maxCapacity: maximum)
            else { return nil }

            return AccessoryBattery(
                name: name,
                vendorID: int(entry[kIOPSVendorIDKey as String]),
                productID: int(entry[kIOPSProductIDKey]),
                part: AccessoryBattery.part(entry[kIOPSPartIdentifierKey] as? String),
                percent: percent
            )
        }
    }

    // MARK: - The undeclared symbol

    private typealias CopyPowerSourcesByType = @convention(c) (Int32) -> Unmanaged<CFArray>?

    /// Resolved once. `dlsym` over RTLD_DEFAULT searches every image already loaded, and IOKit is
    /// linked into the app for the Mac's own battery, so no dlopen is needed.
    private static let copyByType: CopyPowerSourcesByType? = {
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(RTLD_DEFAULT, "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(symbol, to: CopyPowerSourcesByType.self)
    }()

    /// Determined by enumeration, since the constant is published nowhere: on macOS 15, type 0
    /// returns everything, 1 and 3 the internal battery, 2 and 5 nothing, and 4 exactly the
    /// accessories. The Type filter above is what actually guarantees the contents.
    private static let accessorySourceType: Int32 = 4

    // Keys the public IOPSKeys.h does not declare. Spelled out rather than guessed: these are the
    // strings the records carry, read off a live dump.
    private static let kIOPSAccessoryType = "Accessory Source"
    private static let kIOPSProductIDKey = "Product ID"
    private static let kIOPSPartIdentifierKey = "Part Identifier"

    /// CFNumber bridges to NSNumber, which is not always an Int on the Swift side depending on how
    /// the value was boxed — so accept either rather than dropping a reading on a cast.
    private static func int(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
