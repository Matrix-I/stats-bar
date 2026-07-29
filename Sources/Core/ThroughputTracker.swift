// ThroughputTracker.swift — session totals and the live per-second rate, accumulated across byte-counter
// samples.
//
// Unlike MemoryBuckets and CPULoad, this one carries STATE between ticks: a baseline (what the counters
// read when the session or the interface started) and the previous sample (what the rate is measured
// against). That state is the whole reason it is worth extracting — five separate conditions decide what
// happens to a sample, and every one of them exists because of something that actually goes wrong on a
// real machine: an interface bounce restarting the counters at zero, a Wi-Fi→Ethernet switch, two samples
// arriving too close together to divide by, a disconnection, and the very first sample having nothing to
// measure against.
//
// The clock is a parameter rather than a call to DispatchTime.now() inside, which is what makes the rate
// testable at all: a rate is a quantity per unit time, and there is no asserting on one whose denominator
// the function reads for itself.

import Foundation

struct ThroughputTracker {
    /// One reading of an interface's cumulative byte counters.
    struct Sample: Equatable {
        /// BSD name (en0, en7…). The rate and the session total are per-interface: switching from Wi-Fi
        /// to Ethernet has to restart both rather than diff one interface's counters against another's.
        var interface: String
        var rxBytes: UInt64
        var txBytes: UInt64
    }

    struct Reading: Equatable {
        var downloadTotal: UInt64 = 0   // bytes since the session baseline
        var uploadTotal: UInt64 = 0
        var downloadRate: Double = 0    // bytes per second over the last measured interval
        var uploadRate: Double = 0
    }

    /// Shortest interval a rate is divided by. Below this the quotient is dominated by when the sample
    /// happened to land rather than by the traffic, so the previous rate is held instead — a 20 ms gap
    /// with one 1500-byte frame in it would otherwise read as 75 KB/s.
    static let minimumInterval: Double = 0.2

    private var baselineInterface: String?
    private var baselineRx: UInt64 = 0
    private var baselineTx: UInt64 = 0
    private var lastRx: UInt64 = 0
    private var lastTx: UInt64 = 0
    private var lastSampleNanos: UInt64?

    /// The last values produced. Held rather than recomputed so a tick that declines to measure (too
    /// soon, or disconnected) leaves the panel showing the last real figures instead of blanking.
    private(set) var reading = Reading()

    /// Start (or restart) the session from this sample: it becomes both the baseline the totals count
    /// from and the reference the next rate is measured against.
    mutating func prime(with sample: Sample, atNanoseconds now: UInt64) {
        baselineInterface = sample.interface
        baselineRx = sample.rxBytes
        baselineTx = sample.txBytes
        lastRx = sample.rxBytes
        lastTx = sample.txBytes
        lastSampleNanos = now
    }

    /// Fold one sample in and return the current figures. Pass nil when there is no primary interface.
    ///
    /// `now` must come from a monotonic clock (DispatchTime.uptimeNanoseconds); it is only ever used as a
    /// difference against the previous sample's value.
    @discardableResult
    mutating func update(with sample: Sample?, atNanoseconds now: UInt64) -> Reading {
        guard let sample else {
            // Fully disconnected. Collapse the live rate so the menu-bar glyph stops drawing a frozen
            // last value while the popover says "No active connection", and forget the sample time so the
            // next connection re-primes from its first sample rather than dividing the whole offline gap.
            // Totals are cumulative for the session and deliberately survive.
            reading.downloadRate = 0
            reading.uploadRate = 0
            lastSampleNanos = nil
            return reading
        }

        // Restart the session when the interface changed, or when the counters ran backwards — an
        // interface bounce restarts them at zero, and without this the totals below would underflow.
        // Note this leaves lastSampleNanos == now, so no rate is measured on the restarting tick.
        if baselineInterface != sample.interface
            || sample.rxBytes < baselineRx || sample.txBytes < baselineTx {
            prime(with: sample, atNanoseconds: now)
        }

        reading.downloadTotal = sample.rxBytes - baselineRx
        reading.uploadTotal = sample.txBytes - baselineTx

        guard let last = lastSampleNanos else {
            // First sample after priming or a disconnection: nothing to measure against yet.
            lastSampleNanos = now
            lastRx = sample.rxBytes
            lastTx = sample.txBytes
            return reading
        }

        // `now > last` because the clock is monotonic; checked rather than assumed so that a caller
        // passing something else gets no reading instead of a trapping subtraction.
        guard now > last else { return reading }
        let dt = Double(now - last) / 1_000_000_000
        guard dt > Self.minimumInterval else { return reading }

        // The >= guards catch a counter that reset between two samples without the interface name
        // changing: report no traffic for that interval rather than a wrapped, enormous rate.
        reading.downloadRate = Double(sample.rxBytes >= lastRx ? sample.rxBytes - lastRx : 0) / dt
        reading.uploadRate = Double(sample.txBytes >= lastTx ? sample.txBytes - lastTx : 0) / dt
        lastRx = sample.rxBytes
        lastTx = sample.txBytes
        lastSampleNanos = now
        return reading
    }
}
