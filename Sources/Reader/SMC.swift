// SMC.swift — reads power-rail sensors straight from the AppleSMC user client.
//
// The same source iStat Menus' POWER section uses, and (unlike the AppleSmartBattery gauge) it
// refreshes at roughly 1 Hz. No root or entitlement needed. Every rail is a `flt ` (little-endian
// Float32) key in Watts. SMC key names are chip-specific, so `readFloat` returns nil for any key
// this Mac doesn't expose.

import Foundation
import IOKit

final class SMC {
    /// The one AppleSMC connection, shared by every reader (BatteryReader, CPUReader). There's a single
    /// SMC on the machine, so opening one user client and reusing it — rather than one per reader —
    /// keeps a single IOServiceOpen handle and one shared KeyInfo cache. Safe as a singleton because
    /// every caller touches it only from the main thread (see keyInfoCache).
    static let shared = SMC()

    private var conn: io_connect_t = 0
    private(set) var isAvailable = false

    /// Successful KeyInfo lookups, keyed by SMC key name. A key's layout (`flt `, size 4) is fixed for
    /// the machine's lifetime, so readFloat caches it and skips the extra READ_KEYINFO syscall on every
    /// subsequent read of the same key. Single-thread: the shared SMC is only ever called from the main
    /// thread (both readers' polls, and CPUReader's one-off startup discovery, run there).
    private var keyInfoCache: [String: KeyInfo] = [:]

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
    private static let readIndex: UInt8 = 8     // SMC_CMD_READ_INDEX  (key name at an index)
    private static let readKeyInfo: UInt8 = 9   // SMC_CMD_READ_KEYINFO
    private static let kSMCHandleYPCEvent: UInt32 = 2

    /// Private so `shared` is the only instance — one AppleSMC connection for the whole app.
    private init() {
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

    /// The reverse of fourCC — a 32-bit key back to its four ASCII characters (for key enumeration).
    private func keyString(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: b, encoding: .ascii) ?? ""
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

        // Reuse the cached layout when we've seen this key before; otherwise do the one-time
        // READ_KEYINFO probe and cache it. Only a `flt `/size-4 key is accepted (and cached) — a
        // missing key stays uncached so it keeps probing and is picked up if it ever appears.
        let keyInfo: KeyInfo
        if let cached = keyInfoCache[key] {
            keyInfo = cached
        } else {
            var infoIn = Param(); infoIn.key = k; infoIn.data8 = Self.readKeyInfo
            var infoOut = Param()
            guard call(&infoIn, &infoOut), infoOut.result == 0,
                  infoOut.keyInfo.dataType == fourCC("flt "), infoOut.keyInfo.dataSize == 4 else { return nil }
            keyInfo = infoOut.keyInfo
            keyInfoCache[key] = keyInfo
        }

        var readIn = Param(); readIn.key = k; readIn.keyInfo = keyInfo; readIn.data8 = Self.readBytes
        var readOut = Param()
        guard call(&readIn, &readOut), readOut.result == 0 else { return nil }

        let raw = UInt32(readOut.bytes.0)
                | (UInt32(readOut.bytes.1) << 8)
                | (UInt32(readOut.bytes.2) << 16)
                | (UInt32(readOut.bytes.3) << 24)
        return Double(Float(bitPattern: raw))
    }

    /// Enumerates every SMC key by index (`#KEY` gives the count, then `SMC_CMD_READ_INDEX` maps an
    /// index → key name). Used once at startup to discover which CPU-die temperature sensors this
    /// particular chip exposes (they're named per-chip), so the per-second read only touches keys
    /// that actually exist. Returns [] when SMC is unavailable.
    func allKeyNames() -> [String] {
        guard isAvailable else { return [] }

        // `#KEY` is a ui32 holding the total key count.
        var countIn = Param(); countIn.key = fourCC("#KEY"); countIn.data8 = Self.readKeyInfo
        var countInfo = Param()
        guard call(&countIn, &countInfo), countInfo.result == 0 else { return [] }
        var countRead = Param(); countRead.key = fourCC("#KEY"); countRead.keyInfo = countInfo.keyInfo
        countRead.data8 = Self.readBytes
        var countOut = Param()
        guard call(&countRead, &countOut), countOut.result == 0 else { return [] }
        let count = Int((UInt32(countOut.bytes.0) << 24) | (UInt32(countOut.bytes.1) << 16)
                        | (UInt32(countOut.bytes.2) << 8) | UInt32(countOut.bytes.3))
        guard count > 0, count < 100_000 else { return [] }

        var names: [String] = []
        names.reserveCapacity(count)
        for idx in 0..<count {
            var input = Param(); input.data8 = Self.readIndex; input.data32 = UInt32(idx)
            var output = Param()
            guard call(&input, &output), output.result == 0, output.key != 0 else { continue }
            names.append(keyString(output.key))
        }
        return names
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
