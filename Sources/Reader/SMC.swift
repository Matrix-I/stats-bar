// SMC.swift — reads power-rail sensors straight from the AppleSMC user client.
//
// The same source iStat Menus' POWER section uses, and (unlike the AppleSmartBattery gauge) it
// refreshes at roughly 1 Hz. No root or entitlement needed. Every rail is a `flt ` (little-endian
// Float32) key in Watts. SMC key names are chip-specific, so `readFloat` returns nil for any key
// this Mac doesn't expose.

import Foundation
import IOKit

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

    /// Reads the actual RPM of every fan the SMC exposes. Fan keys are contiguous (F0Ac, F1Ac, …),
    /// so it probes upward and stops at the first missing key — no separate `FNum` read needed, and
    /// it works for any fan count. Returns [] on a fanless Mac or when SMC is unavailable. On Apple
    /// Silicon each F<n>Ac is a `flt ` in RPM, which `readFloat` already handles.
    func readFans() -> [Double] {
        guard isAvailable else { return [] }
        var fans: [Double] = []
        for n in 0..<10 {                                 // 10 is a generous ceiling; no Mac has this many
            guard let rpm = readFloat("F\(n)Ac") else { break }
            fans.append(rpm)
        }
        return fans
    }
}
