// IOKitValues.swift — IOKit value helpers shared by the Mac + iOS readers.
// IORegistry values arrive as NSNumbers; these normalize them to Int, with a signed
// fix-up for the fields IOKit reports as unsigned 32-bit (e.g. Amperage while discharging).

import Foundation

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
