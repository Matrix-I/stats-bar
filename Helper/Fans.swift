// Fans.swift — what the helper does to the fans: put one in manual mode at a speed, drive them all to
// their ceilings, and hand them all back to the SMC.
//
// The sequence, as measured on the M1 Pro this was written on: F<n>Md (`ui8 `) is the mode, 0 for the
// SMC's own controller and 1 for manual; F<n>Tg (`flt `) is the target, and in manual mode it is what
// the fan servoes to. Some Apple Silicon models additionally gate manual mode behind `Ftst`, which has
// to be 1 before F<n>Md is accepted — this machine does not have that key, so it is written only where
// it exists. Every number written comes out of FanTarget, the clamp both binaries compile.

import Foundation

final class Fans {
    private let smc: SMCWriter
    /// Fans this helper has put in manual mode since it last restored Auto. The watchdog and `ping`
    /// both key off it being non-empty.
    private(set) var overridden: Set<Int> = []

    init(smc: SMCWriter) { self.smc = smc }

    /// FNum, bounded to the protocol's index range. The bound is applied to the Double, before the
    /// Int conversion: SMCWriter.read has already refused non-finite values, and clamping first means
    /// the conversion can never be handed something out of Int's range.
    var count: Int {
        guard let n = smc.read("FNum") else { return 0 }
        return Int(min(Double(FanCommand.fanIndices.upperBound), max(0, n)))
    }

    private func limits(_ fan: Int) -> (minimum: Double, maximum: Double)? {
        guard let lo = smc.read("F\(fan)Mn"), let hi = smc.read("F\(fan)Mx") else { return nil }
        return (lo, hi)
    }

    func set(fan: Int, rpm: Double) throws {
        guard fan < count else { throw FanError("fan \(fan) does not exist") }
        guard let l = limits(fan),
              let target = FanTarget.clamped(rpm: rpm, minimum: l.minimum, maximum: l.maximum) else {
            throw FanError("fan \(fan) publishes no usable speed range")
        }
        try drive(fan: fan, to: target)
    }

    func driveAllToMax() throws {
        let all = (0..<count).compactMap { fan in limits(fan).map { (fan: fan, minimum: $0.minimum, maximum: $0.maximum) } }
        let targets = FanTarget.maxTargets(all)
        guard !targets.isEmpty else { throw FanError("no fan publishes a usable speed range") }
        for t in targets { try drive(fan: t.fan, to: t.rpm) }
    }

    private func drive(fan: Int, to rpm: Double) throws {
        if smc.exists("Ftst") { try smc.writeUInt8("Ftst", 1) }
        try smc.writeUInt8("F\(fan)Md", 1)
        overridden.insert(fan)
        // The target write is retried briefly: on some Apple Silicon models the SMC takes a moment to
        // act on the mode change and refuses F<n>Tg until it has. Half a second is far longer than
        // that settle; a key that still refuses after it is reported, not retried forever.
        var lastError: Error?
        for _ in 0..<10 {
            do { try smc.writeFloat("F\(fan)Tg", Float(rpm)); return } catch { lastError = error }
            usleep(50_000)
        }
        throw lastError ?? FanError("F\(fan)Tg could not be written")
    }

    /// Every fan back under SMC control. Best effort by design: this runs on the way out of every
    /// failure path, so one fan refusing must not stop the others from being handed back. Writes to
    /// all fans, not only the ones in `overridden` — at startup the set is empty but a previous
    /// instance of the helper may have died with fans still in manual mode.
    func restoreAuto() {
        for fan in 0..<count where smc.exists("F\(fan)Md") {
            do { try smc.writeUInt8("F\(fan)Md", 0) } catch { log("restoreAuto: \(error)") }
        }
        if smc.exists("Ftst") {
            do { try smc.writeUInt8("Ftst", 0) } catch { log("restoreAuto: \(error)") }
        }
        overridden.removeAll()
    }
}

struct FanError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(Date()) \(message)\n".utf8))
}
