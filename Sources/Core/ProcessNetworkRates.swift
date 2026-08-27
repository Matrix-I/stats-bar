// ProcessNetworkRates.swift — cumulative per-process byte counters in, a ranked live rate out.
//
// The counters nettop reports are lifetime totals, and the table wants "who is using the network
// right now", so every figure on screen is a difference between two samples divided by the time
// between them. That is the same shape as ThroughputTracker, and it is here for the same reason:
// state carried between ticks, with several conditions deciding what happens to a sample, each of
// them something that actually occurs on a running machine rather than a hypothetical.
//
//   • The first sample has nothing to measure against. Treating "no previous value" as "previous was
//     zero" would divide a process's whole lifetime of traffic by one tick — a browser that has moved
//     4 GB since login would enter the table at several gigabytes a second and own it forever.
//   • So would a process that appears mid-session, which is the same bug arriving one tick later.
//   • A pid is reused after its process exits, and the new occupant's counters start at zero. The
//     subtraction then goes negative — and on unsigned counters in a binary this repo ships at -O,
//     that is a crash, not a wrap. CLAUDE.md says so in as many words.
//   • The machine sleeps with the popover open. On wake, a real delta divided by a real interval is
//     arithmetically fine and completely misleading: eight hours of traffic averaged into a number
//     labelled as the current rate.
//   • Two samples land close enough together that the quotient measures scheduling jitter rather than
//     traffic — ThroughputTracker's problem exactly, solved the same way.
//
// The clock is a parameter, not a call to DispatchTime.now() inside. A rate is a quantity per unit
// time and there is no asserting on one whose denominator the function reads for itself.

import Foundation

/// One process's measured throughput over the last interval.
struct ProcessNetworkRate: Equatable, Identifiable {
    var pid: Int
    var command: String
    var bytesInPerSec: Double
    var bytesOutPerSec: Double

    var id: Int { pid }
    /// What the table ranks on. Download and upload are one figure here because the question the
    /// table answers is "which process is using the link", and a process saturating it upward is as
    /// much the answer as one saturating it downward.
    var totalPerSec: Double { bytesInPerSec + bytesOutPerSec }
}

struct ProcessNetworkRates {
    /// Shortest interval a rate is divided by, matching ThroughputTracker. Below this the quotient is
    /// dominated by when the sample happened to land rather than by the traffic.
    static let minimumInterval: Double = 0.2

    /// Longest interval still treated as a measurement. Past it the samples are re-primed and no rate
    /// is reported, because the average over a gap that long is not the "now" the column claims to
    /// show. Ten seconds is comfortably above the one-second poll and well below any gap that means
    /// something stopped — a slept machine, a stalled timer, a popover reopened after lunch.
    static let maximumInterval: Double = 10

    /// Previous counters per pid. Keyed by pid and re-primed whenever the counters move backwards or
    /// the accounting name changes, which is how pid reuse is caught.
    private var previous: [Int: ProcessNetworkSample] = [:]
    private var lastSampleNanos: UInt64?

    /// The last rates produced. Held rather than recomputed so a tick that declines to measure leaves
    /// the table showing real figures instead of blanking — the same choice ThroughputTracker makes.
    private(set) var rates: [ProcessNetworkRate] = []

    /// Whether a measurement has ever completed. An empty `rates` is ambiguous on its own — processes
    /// that moved nothing are not rows, so a quiet machine and a tracker that has only ever seen its
    /// first sweep both come out empty — and the view says different things about the two. Without
    /// this the idle case reads "Measuring…" forever.
    private(set) var hasMeasured = false

    init() {}

    /// Feed one sweep of counters. Returns the rates now in force, ranked, highest first.
    ///
    /// `now` is a monotonic clock reading (DispatchTime.uptimeNanoseconds), so it cannot go backwards
    /// across a clock adjustment the way a wall clock can.
    @discardableResult
    mutating func update(with samples: [ProcessNetworkSample], atNanoseconds now: UInt64) -> [ProcessNetworkRate] {
        defer { prime(with: samples, at: now) }

        guard let last = lastSampleNanos else { return [] }   // first sweep: nothing to measure against
        // Subtracting monotonic readings, so `now` should never precede `last`; guarded anyway because
        // the alternative on UInt64 is a trap rather than a negative number.
        let elapsed = now >= last ? Double(now - last) / 1_000_000_000 : 0
        guard elapsed >= Self.minimumInterval else { return rates }
        guard elapsed <= Self.maximumInterval else {
            rates = []
            return rates
        }

        hasMeasured = true
        var measured: [ProcessNetworkRate] = []
        for sample in samples {
            // No previous reading means this process is new to us — either the first time we have
            // seen the machine at all, or a process that started since the last sweep. Its lifetime
            // total is not a rate, so it is primed now and measured from the next sweep.
            guard let before = previous[sample.pid] else { continue }
            // A pid whose counters fell, or whose accounting name changed under it, is a different
            // process wearing the same number. Skip it this round and let the prime below re-baseline.
            guard before.command == sample.command,
                  sample.bytesIn >= before.bytesIn,
                  sample.bytesOut >= before.bytesOut else { continue }
            let deltaIn = Double(sample.bytesIn - before.bytesIn)
            let deltaOut = Double(sample.bytesOut - before.bytesOut)
            guard deltaIn > 0 || deltaOut > 0 else { continue }   // idle processes are not table rows
            measured.append(ProcessNetworkRate(pid: sample.pid, command: sample.command,
                                               bytesInPerSec: deltaIn / elapsed,
                                               bytesOutPerSec: deltaOut / elapsed))
        }
        rates = Self.rank(measured)
        return rates
    }

    /// Highest combined rate first, with the pid breaking ties so the order is total rather than
    /// merely sorted — two idle-but-equal rows must not swap places between ticks and make the table
    /// flicker, and a test cannot pin an order that depends on the input's arrangement.
    static func rank(_ rates: [ProcessNetworkRate]) -> [ProcessNetworkRate] {
        rates.sorted {
            $0.totalPerSec != $1.totalPerSec ? $0.totalPerSec > $1.totalPerSec : $0.pid < $1.pid
        }
    }

    /// Replace the baseline wholesale. Processes absent from this sweep are dropped rather than kept,
    /// so the map tracks the machine instead of growing for as long as the app runs.
    private mutating func prime(with samples: [ProcessNetworkSample], at now: UInt64) {
        previous = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        lastSampleNanos = now
    }
}
