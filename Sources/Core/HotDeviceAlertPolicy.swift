// HotDeviceAlertPolicy.swift — decides WHEN a hot-battery alert should fire. It does not fire one:
// delivery (a real notification, or the HUD fallback) stays in TemperatureAlerter, which needs AppKit and
// a user's permission state and so can't be reached from a test.
//
// The decision is a small state machine with hysteresis, and hysteresis is the kind of thing that fails
// quietly in exactly one direction — either it never re-arms (one alert per boot, and the user stops
// trusting it) or it re-arms every tick (an alert per second at 39.0 °C, and the user turns it off).
// Neither shows up in a screenshot, and both need a sequence of readings to reproduce, which is precisely
// what a test can do and manual checking can't.

import Foundation

struct HotDeviceAlertPolicy {
    /// Alert once a battery reaches this. iOS itself already pauses charging when it runs hot; this is
    /// only a nudge to pull the cable sooner.
    static let defaultThresholdC: Double = 39.0

    /// Re-arm only after the battery cools this far below the threshold, so a reading hovering around the
    /// threshold doesn't fire a fresh alert on every poll.
    static let defaultRearmMarginC: Double = 2.0

    var thresholdC: Double = defaultThresholdC
    var rearmMarginC: Double = defaultRearmMarginC

    /// Device ids currently in the "already alerted" state. Exposed read-only because it is the whole
    /// state of the machine, and a test that can see it can pin the re-arm behaviour directly.
    private(set) var alerted: Set<String> = []

    /// The devices that should be alerted about right now, paired with the temperature to report.
    ///
    /// Generic over the device type so this stays free of the model layer (IOSDeviceInfo is Identifiable
    /// and carries far more than is needed here); call it with key paths — `id: \.id,
    /// temperature: \.temperatureC`.
    mutating func devicesToAlert<Device>(
        _ devices: [Device],
        enabled: Bool,
        id: (Device) -> String,
        temperature: (Device) -> Double?
    ) -> [(device: Device, temperatureC: Double)] {
        // Forget devices that are no longer present, so a device that is unplugged while hot and plugged
        // back in alerts again rather than being remembered as "already warned".
        alerted.formIntersection(Set(devices.map(id)))

        // Turning the alert off clears the state as well as suppressing it: switching it back on should
        // warn about a device that is hot right then, not stay silent because it was hot earlier.
        guard enabled else {
            alerted.removeAll()
            return []
        }

        var fire: [(device: Device, temperatureC: Double)] = []
        for device in devices {
            // A locked or partially-read device leaves temperature nil — nothing to judge, skip it. It
            // deliberately does NOT clear the alerted state: a device that goes quiet while hot hasn't
            // cooled down.
            guard let temp = temperature(device) else { continue }
            let key = id(device)
            if temp >= thresholdC {
                // insert().inserted is what makes this fire exactly once per heat-up.
                if alerted.insert(key).inserted { fire.append((device, temp)) }
            } else if temp <= thresholdC - rearmMarginC {
                alerted.remove(key)
            }
            // Between the two: still warm, already warned. Neither fire nor re-arm — the dead band that
            // stops a reading wobbling around the threshold from alerting on every poll.
        }
        return fire
    }
}
