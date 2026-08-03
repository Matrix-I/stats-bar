// DevicePresenceCache.swift — decides WHAT to show for each attached iPhone/iPad or Android device when
// this tick's read was incomplete, and holds the per-device cache that decision rests on.
//
// Split out of IOSDeviceReader.publish and AndroidDeviceReader.publish, which held ~80 near-identical
// lines of it each. Worth extracting for the same reason HotDeviceAlertPolicy was: every failure mode here
// needs a SEQUENCE of ticks to reproduce, so none of it is visible in a screenshot or reachable by
// clicking around. The repo has already shipped one bug of exactly this shape — reused stale entries
// carried errorMessage == nil, so counting them kept resetting the timer and an enumerated-but-unreadable
// device would never time out (239a191). That is three ticks deep and invisible in any single frame.
//
// IOSDeviceReader is the most fix-touched file under Sources/, and this was the part of it with no I/O in
// it. What stays behind in the readers is the model-specific work: classifying a read, copying the health
// figures across on a graft, and setting isStale. What moves here is every decision about time.
//
// The clock is a parameter, never Date() inside — the same reason ThroughputTracker takes one. Grace
// windows measured against a clock the function reads for itself cannot be asserted at all.

import Foundation

/// Presence/staleness cache for one reader's devices, generic over the reader's own model type so this
/// stays free of Sources/Model. `ID` is the stable device identity: a UDID for iOS, a serial for Android.
///
/// Call it with closures, the way HotDeviceAlertPolicy is called: `id: \.id, kind: classify,
/// capturedAt: \.capturedAt`.
struct DevicePresenceCache<Device, ID: Hashable> {

    /// What a fresh read of one device turned out to be. The reader decides this — the distinction is
    /// model-specific (a locked iPhone, a light glyph-only pass, an adb error string) — and everything
    /// downstream of it is not.
    enum ReadKind: Equatable {
        /// Complete and trustworthy. Shown as read, and becomes this device's cached baseline.
        case good
        /// Live but incomplete because the DEVICE refused part of the read — a locked iPhone, whose
        /// diagnostics registry is unavailable while the lockdown battery domain still answers. Shown with
        /// the cached baseline's static figures grafted on, and deliberately NEVER made the baseline
        /// itself — letting a partial read overwrite the baseline is how cached health gets lost.
        ///
        /// "Refused" is the whole meaning, and it used to be two: a cheap glyph-only pass, where the
        /// caller chose not to ask, arrived here as well. The two look identical to this type and are not
        /// remotely alike in how stale the missing figures may be — a refusal lasts as long as the phone
        /// stays locked, while a skipped read was current seconds ago. Conflating them is how a card ended
        /// up either dropping rows once a second or, had the obvious fix landed, presenting borrowed
        /// numbers as live. If a cheap read is ever reintroduced, give it its own kind and state what
        /// bounds its age before grafting anything that moves.
        case partial
        /// The read failed outright: untrusted, handshake dropped, adb error.
        case failed
    }

    /// What to show for one device, in display order.
    enum Resolved {
        /// The fresh read exactly as it came back. Either a good read, or a failed one whose grace has
        /// run out — in which case showing it as-is is what surfaces its error.
        case fresh(Device)
        /// A partial read, plus the cached baseline to lift the static figures from. The reader does the
        /// copying, because which fields are "static health" is a property of its model.
        case grafted(fresh: Device, baseline: Device)
        /// This device's read failed, but its own last good read is recent enough to ride out, so the
        /// cached reading stands in. The reader flags it stale.
        case cachedStale(Device)
    }

    /// How long a device may be absent from enumeration before its cache entry is dropped and it
    /// disappears from the UI. Short, because vanishing off the bus is usually a real unplug.
    ///
    /// It must still be LONGER than the caller's polling interval, or it cannot fire at all: the previous
    /// sighting is already older than the window by the time the next tick enumerates, so `seenWithin` is
    /// false and the first blip drops the device — a safety net that reads like one and catches nothing.
    /// A `var` rather than a `let` for exactly that reason: a caller whose cadence changes has to move this
    /// with it. See DeviceReadCadence.graceGone, which derives it.
    var graceGone: TimeInterval

    /// How long a device that is still enumerated but unreadable may ride out on its last good read.
    /// Much longer, because that state (locked, or another process holding the lockdown session) tends
    /// to recover on its own.
    var graceUnreadable: TimeInterval

    /// Last time each id appeared in a fresh enumeration — including devices that enumerated but failed
    /// to read, which count as present. Per-device on purpose: one global timestamp cannot express
    /// "device A left but device B is fine", and conflating them is how a healthy sibling ends up
    /// resetting another device's timer.
    private(set) var lastSeenAt: [ID: Date] = [:]

    /// The last good read of each device, in cache order. Exposed read-only because it is the state
    /// every decision below depends on, so a test that can see it can pin the cache behaviour directly.
    private(set) var baseline: [Device] = []

    init(graceGone: TimeInterval, graceUnreadable: TimeInterval = 30) {
        self.graceGone = graceGone
        self.graceUnreadable = graceUnreadable
    }

    /// Fold this tick's enumeration in and say what to show for each device.
    ///
    /// `now` must come from a wall clock (Date), not a monotonic one: the windows are compared against
    /// `capturedAt` timestamps that the readers stamp with Date(), and mixing the two would compare
    /// quantities with different origins.
    mutating func resolve(
        _ fresh: [Device],
        now: Date,
        id: (Device) -> ID,
        kind: (Device) -> ReadKind,
        capturedAt: (Device) -> Date?
    ) -> [Resolved] {
        for device in fresh { lastSeenAt[id(device)] = now }

        // An id last seen longer ago than the gone window cannot change any answer below: seenWithin is
        // false for a stale entry and for a missing one alike. Dropping it keeps this dictionary from
        // growing by one entry per device ever attached in the session.
        defer { lastSeenAt = lastSeenAt.filter { now.timeIntervalSince($0.value) < graceGone } }

        // Nothing enumerated — the bus is empty. Ride out a one-tick blip on whatever was seen recently,
        // then let it go: a deliberate unplug should clear in a few seconds rather than linger.
        //
        // The baseline is deliberately NOT pruned on this path. It is pruned only on a tick that
        // enumerated something, which is what stops a departed device lingering and then briefly
        // resurrecting later; pruning here as well would change when a returning device loses its
        // grafted health.
        if fresh.isEmpty {
            return baseline.filter { seenWithin(graceGone, id($0), now) }.map { .cachedStale($0) }
        }

        var shown: [Resolved] = []
        var good: [Device] = []
        for device in fresh {
            switch kind(device) {
            case .good:
                shown.append(.fresh(device))
                good.append(device)

            case .partial:
                // Grafted only when there is something to graft from; a first-ever read that arrives
                // partial stands on its own rather than waiting for health it has never had.
                if let prev = cached(id(device), id: id) {
                    shown.append(.grafted(fresh: device, baseline: prev))
                } else {
                    shown.append(.fresh(device))
                }

            case .failed:
                // The window is measured from THIS device's own last good read, not from the last time
                // anything succeeded. Measuring it globally is what let a healthy sibling refreshing at
                // 1 Hz keep resetting a broken device's timer, so its error never surfaced.
                if let prev = cached(id(device), id: id), let cap = capturedAt(prev),
                   now.timeIntervalSince(cap) < graceUnreadable {
                    shown.append(.cachedStale(prev))
                } else {
                    shown.append(.fresh(device))
                }
            }
        }

        // Merge rather than replace, so a device that read fully this tick updates its own entry while a
        // sibling that is locked or failing keeps the health it already had. Replacing the whole cache
        // with this tick's good reads would let one healthy device evict every other device's baseline.
        for g in good {
            if let i = baseline.firstIndex(where: { id($0) == id(g) }) { baseline[i] = g }
            else { baseline.append(g) }
        }
        // Then drop entries whose device has been off the bus longer than the ride-out window.
        baseline = baseline.filter { seenWithin(graceGone, id($0), now) }

        return shown
    }

    /// True when `key` appeared in a fresh enumeration within `window` of `now`. A device never seen is
    /// not "seen long ago" — both answer false, which is what makes pruning lastSeenAt invisible.
    func seenWithin(_ window: TimeInterval, _ key: ID, _ now: Date) -> Bool {
        guard let seen = lastSeenAt[key] else { return false }
        return now.timeIntervalSince(seen) < window
    }

    private func cached(_ key: ID, id: (Device) -> ID) -> Device? {
        baseline.first { id($0) == key }
    }
}

extension DevicePresenceCache.Resolved: Equatable where Device: Equatable {}
