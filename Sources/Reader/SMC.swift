// SMC.swift — reads power-rail sensors straight from the AppleSMC user client.
//
// The same source iStat Menus' POWER section uses, and (unlike the AppleSmartBattery gauge) it
// refreshes at roughly 1 Hz. No root or entitlement needed. Every rail is a `flt ` (little-endian
// Float32) key in Watts. SMC key names are chip-specific, so `readFloat` returns nil for any key
// this Mac doesn't expose.

import Foundation
import IOKit

@MainActor
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

    /// Returns the value of a numeric SMC key in its native unit (Watts for the P* rails, RPM for the
    /// fans, °C for the Intel TC** temperatures), or nil if SMC is unavailable, the key is missing, or
    /// its layout isn't supported. Handles `flt ` (little-endian Float32) and `sp78` (big-endian signed
    /// 8.8 fixed-point — the classic Intel CPU-die temperature keys).
    func readFloat(_ key: String) -> Double? {
        guard isAvailable else { return nil }
        let k = fourCC(key)

        // Reuse the cached layout when we've seen this key before; otherwise do the one-time
        // READ_KEYINFO probe and cache it. Only a supported layout (`flt `/size-4 or `sp78`/size-2) is
        // accepted (and cached) — anything else, or a missing key, stays uncached so it keeps probing
        // and is picked up if it ever appears.
        let keyInfo: KeyInfo
        if let cached = keyInfoCache[key] {
            keyInfo = cached
        } else {
            var infoIn = Param(); infoIn.key = k; infoIn.data8 = Self.readKeyInfo
            var infoOut = Param()
            guard call(&infoIn, &infoOut), infoOut.result == 0 else { return nil }
            // An unsupported layout (or a missing key) stays uncached so it keeps probing and is
            // picked up if it ever appears.
            guard isSupported(infoOut.keyInfo) else { return nil }
            keyInfo = infoOut.keyInfo
            keyInfoCache[key] = keyInfo
        }

        var readIn = Param(); readIn.key = k; readIn.keyInfo = keyInfo; readIn.data8 = Self.readBytes
        var readOut = Param()
        guard call(&readIn, &readOut), readOut.result == 0 else { return nil }
        // A non-finite result is not a reading, so it leaves here the same way a missing key does.
        //
        // Only `flt ` can produce one: decode reinterprets four bytes as a Float32, and every bit
        // pattern is a legal Float — including the NaNs and infinities. `sp78` and the single-byte
        // types are bounded by construction. What made that worth a guard is where the value goes
        // next: the fan and temperature rows print it with Int(v.rounded()), and Int(NaN) TRAPS under
        // the -O the app ships. So a fan key that reads back garbage did not show a wrong RPM, it
        // took the app down on the next popover open, and it would have done so on a machine nobody
        // here has rather than this one. Callers already handle nil — readFans skips the fan,
        // readFloat's optional chain hides the row — so refusing costs a row and saves the process.
        guard let value = decode(readOut, as: keyInfo), value.isFinite else { return nil }
        return value
    }

    /// Whether this reader understands a key's layout: `flt ` (little-endian Float32), `sp78`
    /// (big-endian signed 8.8 fixed-point — the classic Intel CPU-die temperatures), and the two
    /// SINGLE-BYTE integer types.
    ///
    /// Single-byte only, deliberately. Widening past `flt `/`sp78` is what makes `FNum` (the
    /// authoritative fan count) and the `F<n>St` fan-state keys readable — both `ui8 `, both
    /// previously nil — and one byte has no byte order to get wrong.
    ///
    /// The multi-byte integer types (ui16/ui32/si16/si32) are NOT accepted, because their byte order
    /// is not uniform across the SMC and a blanket per-type rule would silently return garbage.
    /// Measured on this M1 Pro against AppleSmartBattery as ground truth, the DATA keys are
    /// little-endian: B0CT raw 33 01 → 307 = CycleCount, B0DC raw bb 17 → 6075 = DesignCapacity,
    /// B0FC raw b7 13 → 5047 = AppleRawMaxCapacity — three exact matches. But `#KEY`, also ui32,
    /// is BIG-endian (raw 00 00 08 04 → 2052 keys; byte-swapped it is nonsense), which is why
    /// allKeyNames below decodes it big-endian and gets the right answer. Two orders in one
    /// interface means the type alone does not determine the encoding, so any future multi-byte
    /// support has to validate byte order per key family against a known-good source rather than
    /// assume one. Nothing in the app needs those types today.
    private func isSupported(_ ki: KeyInfo) -> Bool {
        switch (keyString(ki.dataType), ki.dataSize) {
        case ("flt ", 4), ("sp78", 2), ("ui8 ", 1), ("flag", 1):
            return true
        default:
            return false
        }
    }

    /// Turns a successful READ_BYTES reply into a Double in the key's native unit (Watts, RPM, °C,
    /// a count — the key decides). Only layouts `isSupported` admits reach here.
    private func decode(_ p: Param, as ki: KeyInfo) -> Double? {
        var b = [UInt8](repeating: 0, count: 8)
        withUnsafeBytes(of: p.bytes) { raw in
            for i in 0..<min(b.count, raw.count) { b[i] = raw[i] }
        }
        switch keyString(ki.dataType) {
        case "flt ":
            let raw = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            return Double(Float(bitPattern: raw))
        case "sp78":
            // Big-endian, signed, 8 fractional bits — value is raw / 256 (°C for the TC** keys).
            return Double(Int16(bitPattern: (UInt16(b[0]) << 8) | UInt16(b[1]))) / 256.0
        case "ui8 ", "flag":
            return Double(b[0])
        default:
            return nil
        }
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

    /// Every fan the SMC exposes, with the limits that give its speed meaning: actual RPM (F<n>Ac),
    /// the fan's own floor and ceiling (F<n>Mn / F<n>Mx) and the speed the controller is currently
    /// aiming for (F<n>Tg). All four are `flt `. Returns [] on a fanless Mac or when SMC is
    /// unavailable; any individual limit the machine doesn't publish stays nil.
    ///
    /// `FNum` is the authoritative fan count and is only readable now that `ui8 ` decodes — it
    /// replaces the old probe-until-a-key-is-missing loop, which had to guess an upper bound. The
    /// probe remains as the fallback for a chip that doesn't publish FNum.
    func readFans() -> [FanInfo] {
        guard isAvailable else { return [] }
        // roundedInt rather than Int.init: FNum is `ui8 ` on every Mac measured here, so it arrives as
        // 0...255 and the clamp below is what bounds the loop — but the clamp runs AFTER the
        // conversion, and Int.init is the trapping one. A chip that published FNum as `flt ` would
        // therefore crash on the line that exists to make the count safe.
        let declared = readFloat("FNum").map(roundedInt)
        let ceiling = declared.map { max(0, min($0, 64)) } ?? 10
        var fans: [FanInfo] = []
        for n in 0..<ceiling {
            guard let rpm = readFloat("F\(n)Ac") else { break }
            fans.append(FanInfo(index: n,
                                actual: rpm,
                                minimum: readFloat("F\(n)Mn"),
                                maximum: readFloat("F\(n)Mx"),
                                target: readFloat("F\(n)Tg")))
        }
        return fans
    }
}
