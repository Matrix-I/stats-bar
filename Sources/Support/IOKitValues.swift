// IOKitValues.swift — IOKit value helpers shared by the Mac + iOS readers.
// IORegistry values arrive as NSNumbers; these normalize them to Int.
//
// The signed fix-up that used to live here, for the fields IOKit reports as unsigned 32-bit, moved
// into SmartBatteryRegistry when both readers' battery parsing did. It is not duplicated back here:
// every remaining caller of this file wants a plain count, and a second copy of a sign correction is
// exactly the kind of thing that gets fixed in one place only.

import Foundation

func intOrNil(_ any: Any?) -> Int? {
    (any as? NSNumber)?.intValue
}

func intOf(_ any: Any?) -> Int {
    intOrNil(any) ?? 0
}
