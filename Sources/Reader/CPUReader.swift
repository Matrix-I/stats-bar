// CPUReader.swift — the ObservableObject behind the CPU menu-bar item. It publishes a live
// CPUInfo built from three sources, all cheap enough to run on the main thread at ~1 Hz:
//   • host_processor_info(PROCESSOR_CPU_LOAD_INFO) — per-core tick counters. Usage is the DELTA
//     between two samples (busy ticks ÷ total ticks), so a previous snapshot is kept between ticks.
//   • The AppleSMC CPU-die temperature sensors (discovered once at startup — see SMC.allKeyNames).
//   • sysctl — the fixed core topology (how many efficiency vs performance cores) and boot time.
//
// Efficiency vs performance split: on Apple Silicon host_processor_info enumerates the efficiency
// cores at the LOW indices (0 ..< eCoreCount) and the performance cores after them — verified on
// this M1 Pro by pinning QoS-.background spinners (which the scheduler confines to efficiency
// cores) and watching exactly cores 0–1 peg. sysctl hw.perflevel1.logicalcpu gives the efficiency
// count, hw.perflevel0.logicalcpu the performance count.
//
// Like the other readers, work is gated on the popover being open only where it costs something:
// the SMC temperature read is skipped while closed (the menu bar only needs the usage %), but the
// load sample always runs so the menu-bar percentage stays live.

import Foundation
import Combine
import AppKit

@MainActor
final class CPUReader: ObservableObject {
    @Published var info = CPUInfo()

    private lazy var poll = PollingTimer { [weak self] in self?.refresh() }
    // "Is anyone looking?" — the detail popover is open, or the CPU menu-bar item is visible. With
    // neither, nothing shows the data, so the reader stops polling (see applyCadence). itemVisible
    // defaults true to match AppDelegate's lenient "absent key ⇒ shown" default; `polling` tracks
    // whether the timer is currently running so a resume-from-stop can re-prime the delta baseline.
    private var panelOpen = false
    private var itemVisible = true
    private var polling = false
    private let smc = SMC.shared
    private let frequency = CPUFrequency()
    private var cachedFreq: CPUFrequency.Reading? = nil

    // Previous per-core [user, system, idle, nice] tick counts, for the delta computation.
    private var prevTicks: [CoreTicks]? = nil

    // Fixed for the machine's lifetime.
    private let eCoreCount: Int   // efficiency cores (perflevel1) — the low indices
    private let pCoreCount: Int   // performance cores (perflevel0)
    private let chipName: String? // marketing name, e.g. "Apple M1 Pro"
    private let tempKeys: [String]

    // Top-processes list: read via `ps` on a background queue (it blocks briefly), at most once a
    // second, only while the panel is open. Cached so the 1 Hz load path can republish it without
    // re-running ps. cachedTop is touched on the main thread only.
    private var cachedTop: [ProcessSample] = []
    private lazy var topRead = ThrottledBackgroundValue<[ProcessSample]>(label: "CPUReader.top", every: 1)
    nonisolated private static let topCount = 6

    private static let idleInterval: TimeInterval = 2   // menu-bar % only
    private static let activeInterval: TimeInterval = 1 // live readout while the panel is open
    // Low Power Mode: back the menu-bar-only poll off further. The user has explicitly asked macOS to
    // trade responsiveness for battery, and a background sampler is exactly the sort of thing that
    // should take the hint — a stats app that ignores it is working against its own subject.
    private static let lowPowerIdleInterval: TimeInterval = 5

    /// Observer tokens for the two event-driven power signals. Held for the reader's lifetime, which
    /// is the app's — same as AppDelegate's defaultsObserver.
    private var thermalObserver: NSObjectProtocol?
    private var powerObserver: NSObjectProtocol?

    init() {
        eCoreCount = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0
        pCoreCount = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
        chipName = Sysctl.string("machdep.cpu.brand_string")
        tempKeys = Self.discoverTemperatureKeys(smc)

        applyCadence()   // start the idle poll (item visible by default) and mark `polling`
        refresh()        // prime the per-core tick baseline

        // Thermal pressure and Low Power Mode are pushed by the system, so neither needs polling.
        // The power-state hook also re-applies the cadence, so entering Low Power Mode slows the
        // sampler immediately instead of at the next unrelated toggle.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        powerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyCadence(); self?.refresh() }
        }
    }

    /// Poll fast while the panel is visible (and read temperature); drop to the lazy menu-bar-only
    /// cadence when it closes, or stop entirely if the menu-bar item is also hidden (see applyCadence).
    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        applyCadence()
        if open {
            // The IOReport frequency baseline is stale between popover sessions (it only samples while
            // open), so re-prime it so the first reading covers ~1s, not the whole gap (resetBaseline).
            frequency.resetBaseline()
            refresh()
        }
    }

    /// Driven by AppDelegate off the "showCPUItem" toggle. When the item is hidden and the popover is
    /// closed, nothing shows the CPU — stop reading; when it's shown again, repaint now.
    func setItemVisible(_ visible: Bool) {
        guard visible != itemVisible else { return }
        itemVisible = visible
        applyCadence()
        if visible && !panelOpen { refresh() }
    }

    /// Poll cadence from the two visibility signals: fast in the popover, lazy for the menu-bar glyph
    /// alone, stopped when neither shows the data. Resuming after a full stop clears the usage-delta
    /// baseline (tick sampling paused, so it's stale), so the first reading re-primes rather than
    /// averaging over the whole idle gap.
    private func applyCadence() {
        let shouldPoll = panelOpen || itemVisible
        if shouldPoll && !polling { prevTicks = nil }
        polling = shouldPoll
        if panelOpen { poll.schedule(every: Self.activeInterval) }
        else if itemVisible {
            poll.schedule(every: ProcessInfo.processInfo.isLowPowerModeEnabled
                          ? Self.lowPowerIdleInterval : Self.idleInterval)
        }
        else { poll.stop() }
    }

    func refresh() {
        // Nothing displays the CPU when the popover is closed and the item is hidden — skip the read.
        guard panelOpen || itemVisible else { return }
        guard let cur = sampleTicks() else { return }

        var out = CPUInfo()
        out.coreCount = cur.count
        out.efficiencyCoreCount = eCoreCount
        out.performanceCoreCount = pCoreCount
        out.chipName = chipName
        out.uptimeSeconds = Sysctl.uptime()
        out.thermalState = ProcessInfo.processInfo.thermalState
        out.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        out.loadAverage = Self.loadAverage(cores: cur.count)

        // The delta arithmetic lives in CPULoad (Sources/Core), where it is unit-tested. A nil result
        // means the two samples weren't comparable, and leaving `out.load` at its defaults is what the
        // panel wants then: idle 100, no per-core bars, no cluster averages.
        if let prev = prevTicks,
           let load = CPULoad.between(previous: prev, current: cur,
                                      efficiencyCores: eCoreCount, performanceCores: pCoreCount) {
            out.load = load
        }
        prevTicks = cur

        // Temperature only matters inside the popover — skip the SMC reads while it's closed. One
        // reading per die zone, kept in key order so the CORE TEMPERATURES cells stay put between
        // ticks instead of reshuffling as zones overtake each other.
        if panelOpen, !tempKeys.isEmpty {
            let vals = tempKeys.compactMap { smc.readFloat($0) }.filter { $0 > 0 && $0 < 130 }
            if !vals.isEmpty {
                out.coreTemperaturesC = vals
                out.temperatureC = vals.reduce(0, +) / Double(vals.count)
            }
        }

        // Top processes — also popover-only; publish the last list we have.
        if panelOpen { maybeReadTopProcesses() }
        out.topProcesses = cachedTop

        // Frequency (IOReport) — popover-only; the first sample after opening primes the baseline
        // and returns nil, so the value lands one tick later. Keep the last reading meanwhile.
        if panelOpen, frequency.isAvailable, let r = frequency.sample() { cachedFreq = r }
        out.allFrequencyMHz = cachedFreq?.allMHz
        out.efficiencyFrequencyMHz = cachedFreq?.efficiencyMHz
        out.performanceFrequencyMHz = cachedFreq?.performanceMHz

        info = out
    }

    /// Refresh the top-processes list at most once a second, off the main thread (ps blocks briefly).
    private func maybeReadTopProcesses() {
        topRead.request(produce: { Self.readTopProcesses(Self.topCount) }) { [weak self] procs in
            guard let self else { return }
            self.cachedTop = procs
            // Republish right away so the list appears promptly on first open, not one tick later.
            var cur = self.info
            cur.topProcesses = procs
            self.info = cur
        }
    }

    /// The `count` heaviest processes by CPU, exactly as Stats.app reads them: `ps -o pcpu` sorted
    /// descending. `pcpu` is a decaying average over up to a minute (per `man ps`), so the figures
    /// match Stats' rather than jumping around like an instantaneous sample would. `-c` prints the
    /// accounting name, but for GUI apps we prefer NSRunningApplication's localized name and icon (so
    /// it reads "Google Chrome" with its icon, not a truncated "Google Chrome H") — again like Stats.
    /// pid 0 is skipped.
    nonisolated private static func readTopProcesses(_ count: Int) -> [ProcessSample] {
        guard let data = DeviceTool.run("/bin/ps", ["-A", "-c", "-o", "pid=,pcpu=,comm=", "-r"]),
              let out = String(data: data, encoding: .utf8) else { return [] }
        var result: [ProcessSample] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int(parts[0]), let cpu = Double(parts[1]), pid != 0 else { continue }
            let comm = parts[2...].joined(separator: " ")
            let (name, icon) = ProcessList.identity(pid: pid, fallback: comm)
            result.append(ProcessSample(pid: pid, name: name, cpuPercent: cpu, icon: icon))
            if result.count >= count { break }
        }
        return result
    }

    /// The 1/5/15-minute load averages, divided by the logical core count (see CPUInfo.loadAverage
    /// for why normalising is not optional). Uses getloadavg(3) rather than sysctl "vm.loadavg" —
    /// that name returns a `loadavg` struct, so reading it through Sysctl.int would silently decode
    /// the wrong bytes.
    nonisolated private static func loadAverage(cores: Int) -> [Double] {
        guard cores > 0 else { return [] }
        var raw = [Double](repeating: 0, count: 3)
        guard getloadavg(&raw, 3) == 3 else { return [] }
        return raw.map { $0 / Double(cores) }
    }

    // MARK: - Sampling

    /// Per-core tick counters. Frees the kernel-allocated array via vm_deallocate. The CPU_STATE_*
    /// indices are resolved into named fields here so that CPULoad — which does the arithmetic — needs no
    /// knowledge of Mach's array layout.
    private func sampleTicks() -> [CoreTicks]? {
        var count = natural_t(0)
        var infoArray: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)
        // mach_host_self() returns an owned send right and bumps its user-reference count on every call
        // (unlike the cached mach_task_self_), so it must be released or one uref leaks per poll — at the
        // 2 s idle cadence that saturates MACH_PORT_UREFS_MAX within a couple of days and the query then
        // starts failing. Release it whether or not host_processor_info succeeds. Mirrors MemoryStats.swift.
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO,
                                  &count, &infoArray, &infoCount) == KERN_SUCCESS,
              let infoArray else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let buf = UnsafeBufferPointer(start: infoArray, count: Int(infoCount))
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            let base = core * states
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: buf[base + Int(state)]) }
            return CoreTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                             idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    // MARK: - One-off discovery

    /// The CPU-die temperature keys this chip exposes — ONE per thermal zone. Apple Silicon names
    /// them in the 4-char "Tp.." family (all `flt`); an Intel Mac exposes a handful of the classic
    /// TC** keys instead. Probed once at startup so the per-second read only touches keys that exist.
    ///
    /// There are three Tp keys per zone, not one: this M1 Pro publishes 30 of them for a die with 10
    /// core sites, in groups of three that are three renderings of one zone rather than three
    /// sensors. Measured at idle, Tp00 / Tp01 / Tp02 read 51.20 / 60.20 / 67.34, and under load all
    /// three moved by the same delta — the ~9 °C gap between the first two held to the hundredth of a
    /// degree in every group. Averaging all 30 therefore averages three different quantities.
    ///
    /// The last two characters are a base-62 index, which is why the family reads 0,1,2, 4,5,6, 8,9,A,
    /// C,D,E … rather than a contiguous run: index / 4 is the zone, index % 4 the rendering within it.
    /// Rendering 1 is the one taken, matching the keys community sensor tables list as the per-core
    /// reading (here Tp01, Tp05, Tp09, Tp0D, Tp0H, Tp0L, Tp0P, Tp0T, Tp0X, Tp0b). That choice could
    /// not be cross-checked against powermetrics, which needs root; what IS established is that the
    /// three renderings are redundant, so collapsing them to one is right whichever one is picked.
    ///
    /// That thinning only happens on a family with the shape above — contiguous zones from 0, each
    /// publishing renderings 0, 1 and 2. Any other Tp family is kept whole, because a key name cannot
    /// say whether a contiguous `Tp00…Tp07` is eight zones or eight renderings of one, and keeping too
    /// many sensors merely averages a spread while keeping the wrong subset would silently drop most of
    /// an unfamiliar die. SMCKeyName owns the name arithmetic — it's the half of this that runs without
    /// an SMC, and therefore the half under unit test.
    private static func discoverTemperatureKeys(_ smc: SMC) -> [String] {
        if let apple = SMCKeyName.cpuThermalKeys(from: smc.allKeyNames()) { return apple }
        let intel = ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TC1C", "TC2C", "TC3C", "TC4C", "TCXC", "TCAD"]
        return intel.filter { smc.readFloat($0) != nil }
    }
}
