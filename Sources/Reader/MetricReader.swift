// MetricReader.swift — the common surface every metric reader exposes to the Control Center: a
// one-shot refresh and a panel-visibility hint (which lets a reader switch between its idle menu-bar
// cadence and the faster in-popover cadence). Lets the hub drive all readers in one loop instead of
// naming each by hand. The conformances are empty because every reader already implements both
// methods — this only declares that they share a surface.

import Foundation

@MainActor
protocol MetricReader: AnyObject {
    /// Re-read all sources now (used on popover open and by the Refresh button).
    func refresh()
    /// Tell the reader whether its detail popover is visible, so it can pick a polling cadence.
    func setPanelOpen(_ open: Bool)
    /// Tell the reader whether its live menu-bar glyph is currently shown. Together with setPanelOpen
    /// this is the reader's full "is anyone looking?" picture: with the popover closed AND the item
    /// hidden, nothing displays the data, so the reader stops reading until one of them turns back on.
    /// AppDelegate.refreshLabels drives this off the "show<Item>Item" toggles.
    func setItemVisible(_ visible: Bool)
}

extension MetricReader {
    /// Default: the menu-bar item's visibility doesn't change this reader's cadence — used by a reader
    /// whose glyph is static (Bluetooth), so its data is only ever needed while its popover is open.
    func setItemVisible(_ visible: Bool) {}
}

extension BatteryReader: MetricReader {}
extension CPUReader: MetricReader {}
extension MemoryReader: MetricReader {}
extension NetworkReader: MetricReader {}
extension BluetoothReader: MetricReader {}
