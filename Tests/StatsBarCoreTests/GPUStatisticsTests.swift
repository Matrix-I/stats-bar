// GPUStatisticsTests.swift — the accelerator dictionary parse and the energy→watts quotient.
//
// The fixtures are not invented. Each is the "PerformanceStatistics" dictionary read off an M1 Pro's
// AGXAcceleratorG13X entry in three states, because the single most important claim this file pins
// is one that only measurement could establish: a Metal COMPUTE kernel and a Metal RENDER pass move
// DIFFERENT fields. If they moved together the panel should show one ring, not three, and no amount
// of reading the key names would have said which.
//
// The second thing under test is the nil/zero distinction, which is this repo's most expensive
// recurring bug: v2.13.1 shipped a battery card printing "Design capacity: 0 mAh" because an absent
// registry key had been coerced to 0 somewhere, and 0 formats exactly like a measurement. A GPU panel
// has the same failure mode three times over — "Tiler utilization: 0%" is what an idle GPU and a
// GPU with no tiler at all both look like once nil has been lost.

import Testing
@testable import StatsBarCore

@Suite("GPU statistics")
struct GPUStatisticsTests {

    /// The M1 Pro at rest.
    static let idle: [String: Any] = [
        "Device Utilization %": 0,
        "Renderer Utilization %": 0,
        "Tiler Utilization %": 0,
        "In use system memory": 30_507_008,
        "Alloc system memory": 6_021_595_136,
        "recoveryCount": 0,
    ]

    /// The same GPU saturated by a Metal COMPUTE kernel. Device is pegged; the two pipeline stages
    /// are present and reading exactly zero, because a compute dispatch touches neither.
    static let computeLoad: [String: Any] = [
        "Device Utilization %": 97,
        "Renderer Utilization %": 0,
        "Tiler Utilization %": 0,
        "In use system memory": 26_673_152,
        "Alloc system memory": 6_210_551_808,
    ]

    /// The same GPU saturated by a Metal RENDER pass — all three move together.
    static let renderLoad: [String: Any] = [
        "Device Utilization %": 98,
        "Renderer Utilization %": 98,
        "Tiler Utilization %": 98,
        "In use system memory": 31_195_136,
        "Alloc system memory": 6_210_551_808,
        "TiledSceneBytes": 196_608,
    ]

    /// A GPU whose driver publishes no tile-based pipeline at all — the shape an Intel or AMD part
    /// takes, where the tiler key simply does not exist rather than existing and reading zero.
    static let noTiler: [String: Any] = [
        "Device Utilization %": 42,
        "In use system memory": 1_048_576,
    ]

    // MARK: The three figures are three figures

    @Test("A compute kernel pegs the device while the render pipeline stays idle")
    func computeLoadMovesOnlyTheDevice() {
        let s = GPUStatistics.parse(Self.computeLoad)
        #expect(s.deviceUtilization == 97)
        // Present and zero — NOT nil. That difference is the whole argument for three rings: with a
        // compute workload running, "Device 97 / Render 0 / Tiler 0" tells you what kind of work the
        // GPU is doing, and a single ring cannot.
        #expect(s.rendererUtilization == 0)
        #expect(s.tilerUtilization == 0)
    }

    @Test("A render pass moves all three together")
    func renderLoadMovesEverything() {
        let s = GPUStatistics.parse(Self.renderLoad)
        #expect(s.deviceUtilization == 98)
        #expect(s.rendererUtilization == 98)
        #expect(s.tilerUtilization == 98)
    }

    @Test("Idle reads as zero on every figure, and the memory keys still read")
    func idleIsRead() {
        let s = GPUStatistics.parse(Self.idle)
        #expect(s.deviceUtilization == 0)
        #expect(s.rendererUtilization == 0)
        #expect(s.tilerUtilization == 0)
        #expect(s.inUseMemory == 30_507_008)
        #expect(s.allocatedMemory == 6_021_595_136)
    }

    // MARK: Absent is not zero

    @Test("A key the driver never published stays nil rather than becoming a zero reading")
    func absentKeysStayNil() {
        let s = GPUStatistics.parse(Self.noTiler)
        #expect(s.deviceUtilization == 42)
        // The panel hides a nil row. Were these 0, a GPU with no tile-based pipeline would advertise
        // a permanently idle tiler — a measurement of something that does not exist.
        #expect(s.rendererUtilization == nil)
        #expect(s.tilerUtilization == nil)
        #expect(s.allocatedMemory == nil)
    }

    @Test("An empty dictionary yields no readings at all")
    func emptyDictionaryYieldsNothing() {
        #expect(GPUStatistics.parse([:]) == GPUStatistics())
    }

    @Test("Zero and absent are distinguishable, in both directions")
    func zeroIsNotAbsent() {
        let present = GPUStatistics.parse(["Tiler Utilization %": 0])
        let missing = GPUStatistics.parse([:])
        #expect(present.tilerUtilization == 0)
        #expect(missing.tilerUtilization == nil)
        #expect(present != missing)
    }

    // MARK: Values that cannot be plotted

    @Test("A NaN is refused rather than handed to the ring")
    func notANumberIsRejected() {
        // SwiftUI's trim(from:to:) does not reject a NaN — it emits CoreGraphics errors and draws
        // nothing, which reads as a layout bug in a file that has none. Refusing it here turns that
        // into an honestly hidden row.
        let s = GPUStatistics.parse(["Device Utilization %": Double.nan])
        #expect(s.deviceUtilization == nil)
    }

    @Test("An infinite reading is refused")
    func infinityIsRejected() {
        #expect(GPUStatistics.parse(["Device Utilization %": Double.infinity]).deviceUtilization == nil)
        #expect(GPUStatistics.parse(["Device Utilization %": -Double.infinity]).deviceUtilization == nil)
    }

    @Test("A value that is not a number at all is refused")
    func nonNumericValuesAreRejected() {
        #expect(GPUStatistics.parse(["Device Utilization %": "busy"]).deviceUtilization == nil)
        #expect(GPUStatistics.parse(["In use system memory": "lots"]).inUseMemory == nil)
    }

    @Test("Out-of-range percentages clamp instead of vanishing")
    func outOfRangeIsClamped() {
        // The opposite call to the NaN case, and deliberate: 100.0000001 out of a float conversion is
        // a real pegged GPU, and dropping it would blank a working ring at exactly the moment the
        // reading matters most.
        #expect(GPUStatistics.parse(["Device Utilization %": 100.0000001]).deviceUtilization == 100)
        #expect(GPUStatistics.parse(["Device Utilization %": 150]).deviceUtilization == 100)
        #expect(GPUStatistics.parse(["Device Utilization %": -3]).deviceUtilization == 0)
    }

    @Test("A fractional percentage survives the parse")
    func fractionsAreNotTruncated() {
        // Read through doubleValue, not intValue: an AMD driver publishing 12.5 must not arrive as 12.
        #expect(GPUStatistics.parse(["Device Utilization %": 12.5]).deviceUtilization == 12.5)
    }

    @Test("A negative byte count is refused rather than wrapping into an enormous one")
    func negativeMemoryIsRejected() {
        // UInt64(-1) is 18 exabytes, and fmtBytes would print it without complaint.
        #expect(GPUStatistics.parse(["In use system memory": -1]).inUseMemory == nil)
    }
}

@Suite("GPU energy")
struct GPUEnergyTests {

    @Test("Watts match the counters measured on real hardware")
    func measuredCountersGiveMeasuredWatts() {
        // Both windows were read off this M1 Pro's "GPU Energy" channel. The loaded one is the
        // evidence that the unit really is nanojoules: at nJ a saturating Metal kernel gives 8.1 W,
        // which is right for a 14-core integrated GPU, where millijoules would make it 8 kW. The
        // quieter window is kept because it exercises a different magnitude through the same
        // arithmetic, not because 0.15 W is the idle floor — measured idle is nearer 0.0004 W.
        let idle = GPUEnergy.watts(nanojoules: 293_806_250, seconds: 2)
        let loaded = GPUEnergy.watts(nanojoules: 24_239_942_710, seconds: 3)
        #expect(idle != nil && abs(idle! - 0.14690) < 0.0001)
        #expect(loaded != nil && abs(loaded! - 8.07998) < 0.0001)
    }

    @Test("An interval of zero has no quotient")
    func zeroIntervalIsRefused() {
        // Two samples taken in the same instant. Dividing by it is a crash or an infinity depending
        // on the type; both are worse than saying nothing.
        #expect(GPUEnergy.watts(nanojoules: 1_000_000, seconds: 0) == nil)
    }

    @Test("A negative interval is refused")
    func negativeIntervalIsRefused() {
        #expect(GPUEnergy.watts(nanojoules: 1_000_000, seconds: -1) == nil)
    }

    @Test("A counter that went backwards is refused rather than reported as negative power")
    func counterResetIsRefused() {
        // The subscription is re-primed every time the popover reopens, so a delta against a stale
        // baseline can come back negative. -3 W is not a reading anything should print.
        #expect(GPUEnergy.watts(nanojoules: -5_000_000, seconds: 1) == nil)
    }

    @Test("An idle GPU that genuinely burned nothing reads zero, not nil")
    func zeroEnergyIsAReading() {
        // The boundary between the two guards: >= 0 must admit exactly 0, or a fully powered-down
        // GPU would hide the row instead of showing 0.00 W.
        #expect(GPUEnergy.watts(nanojoules: 0, seconds: 1) == 0)
    }
}
