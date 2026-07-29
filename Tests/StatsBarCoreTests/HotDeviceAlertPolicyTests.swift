// HotDeviceAlertPolicyTests.swift — when the hot-battery alert fires.
//
// Hysteresis has two failure modes and both are quiet: never re-arming (one alert per boot, so the user
// stops trusting it) and re-arming every poll (an alert per second while the battery sits at the
// threshold, so the user switches it off). Neither is visible in a single reading — they only appear in a
// SEQUENCE, which is what every test here drives.

import Testing
@testable import StatsBarCore

@Suite("Hot device alert policy")
struct HotDeviceAlertPolicyTests {

    /// Stands in for IOSDeviceInfo. A local type on purpose: the policy is generic precisely so it never
    /// needs the model layer, and using a stub here proves that.
    struct Device: Equatable {
        var id: String
        var temperatureC: Double?
    }

    /// One poll. Returns the ids that would be alerted about.
    static func poll(_ policy: inout HotDeviceAlertPolicy,
                     _ devices: [Device], enabled: Bool = true) -> [String] {
        policy.devicesToAlert(devices, enabled: enabled, id: \.id, temperature: \.temperatureC)
            .map { $0.device.id }
    }

    static func phone(_ temp: Double?, id: String = "udid-1") -> Device {
        Device(id: id, temperatureC: temp)
    }

    // MARK: Firing once

    @Test("fires when the battery reaches the threshold")
    func firesAtThreshold() {
        var p = HotDeviceAlertPolicy()
        #expect(Self.poll(&p, [Self.phone(38.9)]) == [])    // just below
        #expect(Self.poll(&p, [Self.phone(39.0)]) == ["udid-1"])   // inclusive
    }

    @Test("does not fire again while the battery stays hot")
    func firesOnlyOncePerHeatUp() {
        // The whole point of the alerted set. A 1 Hz poll would otherwise deliver 60 notifications a
        // minute for as long as the phone is warm.
        var p = HotDeviceAlertPolicy()
        #expect(Self.poll(&p, [Self.phone(39.5)]) == ["udid-1"])
        #expect(Self.poll(&p, [Self.phone(40.0)]) == [])
        #expect(Self.poll(&p, [Self.phone(42.0)]) == [])
        #expect(Self.poll(&p, [Self.phone(39.0)]) == [])
    }

    // MARK: The dead band

    @Test("cooling into the dead band neither fires nor re-arms")
    func deadBandHoldsState() {
        // 37.0 < temp < 39.0 is the margin. A reading wobbling here must not re-arm, or the next tick
        // back above 39 fires again — the alert-per-second failure, just with two ticks instead of one.
        var p = HotDeviceAlertPolicy()
        #expect(Self.poll(&p, [Self.phone(39.5)]) == ["udid-1"])
        #expect(Self.poll(&p, [Self.phone(38.0)]) == [])   // in the band
        #expect(p.alerted.contains("udid-1"))              // still remembered
        #expect(Self.poll(&p, [Self.phone(39.5)]) == [])   // so this does NOT re-fire
    }

    @Test("re-arms once the battery cools past the margin, then fires again")
    func rearmsBelowTheMargin() {
        var p = HotDeviceAlertPolicy()
        #expect(Self.poll(&p, [Self.phone(40.0)]) == ["udid-1"])
        #expect(Self.poll(&p, [Self.phone(37.0)]) == [])    // 39 − 2, inclusive: re-arms here
        #expect(p.alerted.isEmpty)
        #expect(Self.poll(&p, [Self.phone(39.0)]) == ["udid-1"])   // a genuinely new heat-up
    }

    @Test("the re-arm boundary is 37.0 inclusive")
    func rearmBoundary() {
        // Pinned because it is the arithmetic the two magic numbers combine into. 37.1 is still the dead
        // band; 37.0 is cool enough.
        var stillWarm = HotDeviceAlertPolicy()
        _ = Self.poll(&stillWarm, [Self.phone(40)])
        _ = Self.poll(&stillWarm, [Self.phone(37.1)])
        #expect(stillWarm.alerted.contains("udid-1"))

        var cooled = HotDeviceAlertPolicy()
        _ = Self.poll(&cooled, [Self.phone(40)])
        _ = Self.poll(&cooled, [Self.phone(37.0)])
        #expect(cooled.alerted.isEmpty)
    }

    // MARK: Missing readings

    @Test("a device that stops reporting its temperature is not treated as cooled")
    func nilTemperatureHoldsState() {
        // A locked phone reads nil. Clearing the state on nil would make lock/unlock a re-alert cycle,
        // which is the same alert-storm bug arriving by a different route.
        var p = HotDeviceAlertPolicy()
        #expect(Self.poll(&p, [Self.phone(40.0)]) == ["udid-1"])
        #expect(Self.poll(&p, [Self.phone(nil)]) == [])
        #expect(p.alerted.contains("udid-1"))
        #expect(Self.poll(&p, [Self.phone(40.0)]) == [])   // still remembered
    }

    @Test("a device with no temperature never fires")
    func nilTemperatureNeverFires() {
        var p = HotDeviceAlertPolicy()
        #expect(Self.poll(&p, [Self.phone(nil)]) == [])
        #expect(p.alerted.isEmpty)
    }

    // MARK: Disconnection

    @Test("unplugging a hot device and plugging it back in alerts again")
    func disconnectionForgetsTheDevice() {
        // The reason for formIntersection. Without it, a phone unplugged at 41 °C and reconnected still
        // hot would stay silent for the rest of the session.
        var p = HotDeviceAlertPolicy()
        #expect(Self.poll(&p, [Self.phone(41.0)]) == ["udid-1"])
        #expect(Self.poll(&p, []) == [])          // unplugged
        #expect(p.alerted.isEmpty)
        #expect(Self.poll(&p, [Self.phone(41.0)]) == ["udid-1"])   // reconnected, still hot
    }

    @Test("one device disconnecting does not re-arm another that is still attached")
    func forgettingIsPerDevice() {
        var p = HotDeviceAlertPolicy()
        let a = Self.phone(40.0, id: "a"), b = Self.phone(40.0, id: "b")
        #expect(Set(Self.poll(&p, [a, b])) == ["a", "b"])
        #expect(Self.poll(&p, [a]) == [])            // b unplugged
        #expect(p.alerted == ["a"])                  // a's state survives
        #expect(Self.poll(&p, [a, b]) == ["b"])      // only b alerts again
    }

    // MARK: Multiple devices

    @Test("each device is judged on its own")
    func devicesAreIndependent() {
        var p = HotDeviceAlertPolicy()
        let hot = Self.phone(41.0, id: "hot"), cool = Self.phone(25.0, id: "cool")
        #expect(Self.poll(&p, [hot, cool]) == ["hot"])
        #expect(p.alerted == ["hot"])
    }

    // MARK: The off switch

    @Test("disabling the alert suppresses it and clears the state")
    func disabledSuppressesAndClears() {
        // Clearing matters: turning the toggle back on should warn about a phone that is hot right then,
        // rather than staying silent because it was already hot when the alert was switched off.
        var p = HotDeviceAlertPolicy()
        #expect(Self.poll(&p, [Self.phone(41.0)]) == ["udid-1"])
        #expect(Self.poll(&p, [Self.phone(41.0)], enabled: false) == [])
        #expect(p.alerted.isEmpty)
        #expect(Self.poll(&p, [Self.phone(41.0)]) == ["udid-1"])
    }

    // MARK: Retuning

    @Test("the threshold and margin are configurable together")
    func thresholdsAreConfigurable() {
        // Guards against the two numbers being read from different places — the settings toggle names the
        // threshold in its label, and it used to carry a hand-written copy of it.
        var p = HotDeviceAlertPolicy(thresholdC: 45, rearmMarginC: 5)
        #expect(Self.poll(&p, [Self.phone(44.9)]) == [])
        #expect(Self.poll(&p, [Self.phone(45.0)]) == ["udid-1"])
        #expect(Self.poll(&p, [Self.phone(40.1)]) == [])
        #expect(p.alerted.contains("udid-1"))     // still in the (wider) dead band
        #expect(Self.poll(&p, [Self.phone(40.0)]) == [])
        #expect(p.alerted.isEmpty)                // re-armed at threshold − margin
    }

    @Test("the shipped defaults are 39 °C with a 2 °C margin")
    func defaultsAreTheShippedValues() {
        #expect(HotDeviceAlertPolicy.defaultThresholdC == 39.0)
        #expect(HotDeviceAlertPolicy.defaultRearmMarginC == 2.0)
        #expect(HotDeviceAlertPolicy().thresholdC == 39.0)
        #expect(HotDeviceAlertPolicy().rearmMarginC == 2.0)
    }
}
