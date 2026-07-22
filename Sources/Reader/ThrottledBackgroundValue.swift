// ThrottledBackgroundValue.swift — the one "run a slow read off the main thread, throttled, at most
// one in flight, deliver the result back on main" pattern every reader that shells out (or otherwise
// blocks) shares. BatteryReader (Maximum Capacity via system_profiler), CPUReader / MemoryReader
// (top processes via ps) and BluetoothReader (device list via system_profiler) each hand-rolled the
// same three fields — an in-flight flag, a last-run timestamp, a utility queue — plus a near-identical
// guard; this factors that bookkeeping into one place. The reader-specific work stays in the closures:
// `produce` gathers the value on the background queue, `then` applies it on the main thread.

import Foundation

final class ThrottledBackgroundValue<T> {
    private let queue: DispatchQueue
    private let minInterval: TimeInterval

    // Touched only on the main thread — request() is always called from a reader's main-thread refresh.
    private var inFlight = false
    private var lastRun = Date.distantPast

    init(label: String, every minInterval: TimeInterval, qos: DispatchQoS = .utility) {
        self.queue = DispatchQueue(label: label, qos: qos)
        self.minInterval = minInterval
    }

    /// Kick off `produce` on the background queue unless one is already running, or the throttle
    /// window hasn't elapsed since the last completion (`force` bypasses the window, not the
    /// in-flight guard). `then` runs on the main thread with whatever `produce` returned — including a
    /// nil/empty T, so callers that must always run a side effect (e.g. Bluetooth's GATT refresh) can.
    /// Call from the main thread; the throttle state is not synchronized for concurrent callers.
    func request(force: Bool = false, produce: @escaping () -> T, then: @escaping (T) -> Void) {
        guard !inFlight, force || Date().timeIntervalSince(lastRun) >= minInterval else { return }
        inFlight = true
        queue.async { [weak self] in
            let value = produce()
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastRun = Date()
                self.inFlight = false
                then(value)
            }
        }
    }
}
