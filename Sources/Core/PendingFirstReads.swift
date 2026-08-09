// PendingFirstReads.swift — how long a battery source may keep a row saying "…" before the row is
// entitled to stop waiting on it.
//
// A Bluetooth row has three states, not two: it has a level, it has none, or nobody knows yet. Only
// the middle one may print a dash, so every source has to be able to say when it has finished having
// its say — and BluetoothGATT's answer was "when nothing is outstanding", with no bound on how long
// something may stay outstanding. CBCentralManager.connect has no timeout and no "still trying"
// callback, so a peripheral that is listed as connected and never completes a GATT connection stays
// outstanding for the life of the process. One unreachable mouse then holds EVERY row on the
// ellipsis, permanently, including the rows of devices that answered instantly.
//
// This lives in Core rather than beside the CoreBluetooth code because it is the part with no
// CoreBluetooth in it, and because a deadline is the shape of bug that a screenshot cannot show: the
// broken version and the fixed version render identically for the first few seconds and differ only
// in what happens next. DevicePresenceCache is here for the same reason and states it at more length.
//
// The clock is a parameter, never Date() read inside. A window measured against a clock the type
// reads for itself cannot be asserted at all.

import Foundation

/// The set of first reads a source is still waiting on, each with a deadline.
///
/// Generic over the identifier so this stays free of CoreBluetooth — BluetoothGATT keys peripherals
/// by their per-host UUID.
struct PendingFirstReads<ID: Hashable> {

    /// How long one read may stay outstanding before it stops counting as pending.
    ///
    /// Expiry does not abandon the read — the caller is free to leave its connection attempt running,
    /// and a late answer still publishes. What expires is the CLAIM ON THE ROWS. That asymmetry is
    /// what makes a short deadline safe and a missing one not: too short costs a row that says "no
    /// battery" and then shows one a moment later, while none at all costs a row that says nothing
    /// for as long as the app runs.
    var deadline: TimeInterval

    /// When each outstanding read began. Exposed read-only so a test can pin the bookkeeping directly
    /// rather than inferring it from the answers.
    private(set) var startedAt: [ID: Date] = [:]

    init(deadline: TimeInterval) {
        self.deadline = deadline
    }

    /// Start waiting on `id`.
    ///
    /// An id already in flight keeps its ORIGINAL timestamp. Otherwise a source that re-offers the
    /// same peripheral on every poll would push the deadline out by one interval each time, which is
    /// a deadline that can never be reached — the same defect DeviceReadCadence.graceGone was written
    /// to end, in the other direction.
    mutating func begin(_ id: ID, at now: Date) {
        guard startedAt[id] == nil else { return }
        startedAt[id] = now
    }

    /// Stop waiting on `id` because it answered, whatever the answer was.
    ///
    /// Returns true when that was the last read outstanding, which is the caller's cue to republish —
    /// a row sitting on the ellipsis has nothing else to tell it the wait is over. Returns false for
    /// an id that was not being waited on, so a late callback for an already-expired read cannot
    /// trigger a spurious republish.
    mutating func finish(_ id: ID) -> Bool {
        guard startedAt.removeValue(forKey: id) != nil else { return false }
        return startedAt.isEmpty
    }

    /// Drop every read that has overrun the deadline. Returns true when that settled the source, on
    /// the same terms as `finish`.
    mutating func expire(now: Date) -> Bool {
        let overdue = startedAt.filter { isOverdue($0.value, now) }
        guard !overdue.isEmpty else { return false }
        for id in overdue.keys { startedAt[id] = nil }
        return startedAt.isEmpty
    }

    /// True when nothing is still inside its deadline — so the source has had its say and a row
    /// without a level may call itself batteryless.
    ///
    /// Answers on schedule whether or not `expire` has been called, deliberately: expiry is what
    /// produces the republish, and this is what stops the two disagreeing in between. A caller that
    /// polls infrequently would otherwise report "still waiting" for up to one whole poll after the
    /// deadline had passed.
    func isSettled(now: Date) -> Bool {
        !startedAt.values.contains { !isOverdue($0, now) }
    }

    /// Forget everything, for the transitions where nothing can be in flight any more — a Bluetooth
    /// adapter leaving the powered-on state invalidates every peripheral at once and delivers no
    /// per-device callback to notice it with.
    mutating func removeAll() {
        startedAt.removeAll()
    }

    /// `>=` rather than `>`: a read that has taken exactly the deadline has taken the whole of the
    /// time it was given. The distinction is unobservable against a wall clock and matters only to a
    /// test, which is precisely why it is written down rather than left to whichever the code happened
    /// to use.
    private func isOverdue(_ started: Date, _ now: Date) -> Bool {
        now.timeIntervalSince(started) >= deadline
    }
}
