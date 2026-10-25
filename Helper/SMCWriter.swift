// SMCWriter.swift — the fan helper's own AppleSMC connection, the one part of StatsBar that writes.
//
// Not shared with Sources/Reader/SMC.swift on purpose. That class is @MainActor, read-only and part of
// the app module, which build_app.sh compiles separately from this binary; reusing it would mean
// either dragging the whole app into a root process or loosening the reader for a caller it was never
// written for. What is duplicated is the 80-byte parameter struct and the call, both of which the
// kernel fixes, so the two copies cannot meaningfully drift.
//
// Every write is checked against the key's own description before it is attempted: the type and size
// must be exactly what the caller expects, and the SMC must mark the key writable. Measured on the M1
// Pro this was written on: F<n>Md is `ui8 `/1 with attributes 0xd0 and F<n>Tg is `flt `/4 with 0xd4 —
// both carry 0x40 — while F<n>Mn/F<n>Mx (0x84/0x85) do not, and Ftst does not exist at all. A write
// to the wrong layout would put bytes the SMC interprets differently into a key that drives hardware,
// so a mismatch is refused rather than attempted.

import Foundation
import IOKit

final class SMCWriter {
    private var conn: io_connect_t = 0
    let isAvailable: Bool

    private struct Version { var major: UInt8=0; var minor: UInt8=0; var build: UInt8=0; var reserved: UInt8=0; var release: UInt16=0 }
    private struct PLimit  { var version: UInt16=0; var length: UInt16=0; var cpuPLimit: UInt32=0; var gpuPLimit: UInt32=0; var memPLimit: UInt32=0 }
    // Padded to its 12-byte stride for the same reason as in SMC.swift: without pad0…2 the struct is
    // 76 bytes and the kernel rejects every call.
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
    private static let writeBytes: UInt8 = 6    // SMC_CMD_WRITE_BYTES
    private static let readKeyInfo: UInt8 = 9   // SMC_CMD_READ_KEYINFO
    private static let kSMCHandleYPCEvent: UInt32 = 2
    /// The attribute bit the SMC sets on keys it accepts writes to.
    private static let writableAttribute: UInt8 = 0x40

    enum WriteError: Error, CustomStringConvertible {
        case missing(String)
        case layout(String, found: String)
        case notWritable(String)
        case rejected(String)

        var description: String {
            switch self {
            case let .missing(k): return "\(k) does not exist on this Mac"
            case let .layout(k, found): return "\(k) has layout \(found), refusing to write"
            case let .notWritable(k): return "\(k) is not writable"
            case let .rejected(k): return "the SMC rejected the write to \(k)"
            }
        }
    }

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        var opened = false
        if svc != IO_OBJECT_NULL {
            opened = IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS
            IOObjectRelease(svc)
        }
        isAvailable = opened
    }

    deinit { if isAvailable { IOServiceClose(conn) } }

    private func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    private func typeString(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: b, encoding: .ascii) ?? "????"
    }

    private func call(_ input: inout Param) -> Param? {
        var output = Param()
        var outSize = MemoryLayout<Param>.stride
        guard IOConnectCallStructMethod(conn, Self.kSMCHandleYPCEvent, &input, MemoryLayout<Param>.stride,
                                        &output, &outSize) == KERN_SUCCESS,
              output.result == 0 else { return nil }
        return output
    }

    private func keyInfo(_ key: String) -> KeyInfo? {
        guard isAvailable else { return nil }
        var p = Param(); p.key = fourCC(key); p.data8 = Self.readKeyInfo
        return call(&p)?.keyInfo
    }

    func exists(_ key: String) -> Bool { keyInfo(key) != nil }

    /// A `flt ` or `ui8 ` key as a Double; nil for anything else, a missing key, or a non-finite value
    /// (the same refusal SMC.readFloat makes, and for the same reason: the caller turns it into a write).
    func read(_ key: String) -> Double? {
        guard let info = keyInfo(key) else { return nil }
        var p = Param(); p.key = fourCC(key); p.keyInfo = info; p.data8 = Self.readBytes
        guard let out = call(&p) else { return nil }
        let b = withUnsafeBytes(of: out.bytes) { Array($0.prefix(4)) }
        switch (typeString(info.dataType), info.dataSize) {
        case ("flt ", 4):
            let raw = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            let v = Double(Float(bitPattern: raw))
            return v.isFinite ? v : nil
        case ("ui8 ", 1):
            return Double(b[0])
        default:
            return nil
        }
    }

    func writeUInt8(_ key: String, _ value: UInt8) throws {
        try write(key, type: "ui8 ", bytes: [value])
    }

    /// Little-endian, as every `flt ` key on Apple Silicon reads back (SMC.decode).
    func writeFloat(_ key: String, _ value: Float) throws {
        let raw = value.bitPattern
        try write(key, type: "flt ", bytes: [UInt8(raw & 0xff), UInt8((raw >> 8) & 0xff),
                                            UInt8((raw >> 16) & 0xff), UInt8((raw >> 24) & 0xff)])
    }

    private func write(_ key: String, type: String, bytes: [UInt8]) throws {
        guard let info = keyInfo(key) else { throw WriteError.missing(key) }
        let found = typeString(info.dataType)
        guard found == type, Int(info.dataSize) == bytes.count else {
            throw WriteError.layout(key, found: "\(found)/\(info.dataSize)")
        }
        guard info.dataAttributes & Self.writableAttribute != 0 else { throw WriteError.notWritable(key) }
        var p = Param(); p.key = fourCC(key); p.keyInfo = info; p.data8 = Self.writeBytes
        withUnsafeMutableBytes(of: &p.bytes) { dst in
            for (i, byte) in bytes.enumerated() { dst[i] = byte }
        }
        guard call(&p) != nil else { throw WriteError.rejected(key) }
    }
}
