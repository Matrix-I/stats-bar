// DeviceReadCadence.swift — how often to re-read an attached phone, and how long one may be missing
// before it is dropped. Both answers depend only on who is looking, so neither needs a device.
//
// This was `IOSDeviceReader.tick()`: four intervals as private static constants, an elapsed-time gate
// against a timer running at a different rate, and a `graceGone` literal handed to DevicePresenceCache
// from a third place. Nothing there was reachable by a test, and two defects lived in that shape:
//
//  1. `graceGone` was 3 seconds while two of the four cadences tick every 5 s and 10 s. A ride-out
//     shorter than the interval in force CANNOT FIRE: by the time the next tick enumerates, the previous
//     sighting is already older than the window, so `seenWithin` is false and the device is dropped on
//     the first blip — the exact opposite of what the window exists for. That is why `graceGone` here is
//     derived from the interval rather than written down beside it.
//  2. The intervals were restated in a second place whenever anyone reasoned about them. This type owns
//     them as defaults, and the reader constructs it with no arguments, so a test asserting against
//     `DeviceReadCadence()` is asserting against the numbers the app ships — not against a copy that
//     goes stale the moment someone edits the reader. A cadence test that restates the numbers proves
//     only that the test file agrees with itself.
//
// There is deliberately NO "is a read due yet?" predicate here, and that absence was measured rather
// than assumed. The obvious shape — hold the timer at a flat 1 Hz and gate each tick on elapsed time —
// beats the two rates against each other: a read that starts a few milliseconds after a tick makes the
// next tick see `elapsed` fractionally short of the interval and skip, so an interval of 2 s reads every
// 3 s and an interval of 1 s reads every 1-2 s. Driving the reader's own timer AT the interval instead
// (the pattern BatteryReader.applyCadence already used) removes the second rate, and with it the beat,
// the drift, and the question of what a dropped attempt should record. So this type answers only "how
// often" and "how long may it be missing" — never "now?".

import Foundation

struct DeviceReadCadence {

    /// Who can currently see the readings. The reader derives this from its popover-visibility flag and
    /// the menu-bar toggle; the distinction matters because the three audiences need different things.
    enum Watcher: Equatable {
        /// The popover is open, so the full readout — health, temperature, voltage, power — is on screen.
        case popover
        /// Only the menu-bar glyph is shown. It needs a charge percentage and a charging bolt, nothing else.
        case glyph
        /// Nobody is looking. Reads continue anyway, but only to notice a plug-in and to keep the
        /// hot-battery alert responsive.
        case nobody
    }

    /// Popover open: the numbers are being read, so refresh at the rate a person notices.
    var onScreenInterval: TimeInterval = 1

    /// Glyph only. Deliberately slower than `onScreenInterval` even though the glyph updates every time:
    /// the glyph shows a rounded percentage and a bolt, and iOS itself only refreshes the underlying
    /// AppleSmartBattery snapshot every 7-20 seconds (measured), so reading it every second re-fetches
    /// an identical snapshot. Two seconds halves the subprocess count for no loss of truth.
    var glyphInterval: TimeInterval = 2

    /// Nothing shows the data, but a phone is attached. Frequent enough for the hot-battery nudge —
    /// battery temperature drifts slowly and iOS pauses charging when hot on its own — without forking
    /// libimobiledevice every second for something nobody can see.
    var offScreenInterval: TimeInterval = 5

    /// Nothing attached and nobody watching: just often enough to notice a plug-in promptly.
    var idleInterval: TimeInterval = 10

    /// How much longer than one interval a device may be missing before it is dropped. This is what makes
    /// the ride-out able to fire at all: it has to cover one whole interval (the sighting is already that
    /// old when the next tick looks) plus enough slack for a read that ran long. Small on purpose —
    /// vanishing off the bus is usually a real unplug, and a deliberate unplug should clear in seconds.
    var blipMargin: TimeInterval = 1.5

    /// Seconds between reads for this audience.
    func interval(_ watcher: Watcher, deviceAttached: Bool) -> TimeInterval {
        switch watcher {
        case .popover: return onScreenInterval
        case .glyph:   return glyphInterval
        case .nobody:  return deviceAttached ? offScreenInterval : idleInterval
        }
    }

    /// How long a device may be absent from enumeration before its cached row is dropped — one whole
    /// interval plus `blipMargin`, never a constant. See defect 1 above: a window shorter than the
    /// interval is dead code that reads like a safety net.
    ///
    /// It follows that the window tightens as soon as somebody looks. Opening the popover moves a device
    /// from a 6.5 s ride-out to a 2.5 s one, which is what makes an unplug clear promptly on screen while
    /// still surviving a one-tick enumeration blip off it.
    ///
    /// The tightening applies from the next SIGHTING, not immediately: a device last enumerated under the
    /// slow cadence keeps the window it was seen with until it is seen again. Otherwise the new window is
    /// being applied to a gap that the old cadence chose, which drops the device on the opening edge. See
    /// DevicePresenceCache.Sighting.
    func graceGone(_ watcher: Watcher, deviceAttached: Bool) -> TimeInterval {
        interval(watcher, deviceAttached: deviceAttached) + blipMargin
    }
}
