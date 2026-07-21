// MetricReader.swift — the common surface every metric reader exposes to the Control Center: a
// one-shot refresh and a panel-visibility hint (which lets a reader switch between its idle menu-bar
// cadence and the faster in-popover cadence). Lets the hub drive all readers in one loop instead of
// naming each by hand. The conformances are empty because every reader already implements both
// methods — this only declares that they share a surface.

import Foundation

protocol MetricReader: AnyObject {
    /// Re-read all sources now (used on popover open and by the Refresh button).
    func refresh()
    /// Tell the reader whether its detail popover is visible, so it can pick a polling cadence.
    func setPanelOpen(_ open: Bool)
}

extension BatteryReader: MetricReader {}
extension CPUReader: MetricReader {}
extension MemoryReader: MetricReader {}
extension NetworkReader: MetricReader {}
extension BluetoothReader: MetricReader {}
