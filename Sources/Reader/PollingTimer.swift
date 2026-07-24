// PollingTimer.swift — the one polling pattern every reader shares: a repeating timer on the main
// run loop, registered in .common modes. That mode is the crucial part — a plain scheduledTimer runs
// only in .default, so while a menu-bar popover holds the run loop in event-tracking mode the timer
// would stop firing and the "live" readout would freeze. Each reader used to re-implement this by
// hand (invalidate-before-replace, .common registration, skip-if-interval-unchanged); PollingTimer is
// that logic in one place. Cadence changes go straight through schedule(every:), which no-ops when the
// interval is unchanged, so a reader can drive it off a panel-open toggle without tracking the current
// value itself.

import Foundation

@MainActor
final class PollingTimer {
    private var timer: Timer?
    private var interval: TimeInterval?
    private let handler: @MainActor () -> Void

    /// `handler` runs on the main run loop at each tick. Pass a `[weak self]` closure — PollingTimer is
    /// owned by the reader it calls back into, so a strong capture would retain-cycle. Nothing fires
    /// until `schedule(every:)`.
    init(_ handler: @MainActor @escaping () -> Void) {
        self.handler = handler
    }

    /// Fire `handler` every `seconds` from now on. Reschedules when the interval changes and is a
    /// no-op when it doesn't, so it's safe to call on every cadence toggle. The first tick lands one
    /// interval out (callers needing an immediate read call their own refresh directly first).
    func schedule(every seconds: TimeInterval) {
        guard seconds != interval else { return }
        interval = seconds
        timer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handler()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stop firing until the next `schedule(every:)`. Idempotent; the interval memo is cleared so a
    /// later schedule at the same interval restarts cleanly.
    func stop() {
        timer?.invalidate()
        timer = nil
        interval = nil
    }

    deinit { timer?.invalidate() }
}
