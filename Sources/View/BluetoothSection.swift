// BluetoothSection.swift — the Bluetooth menu-bar item's popover: a centred "Bluetooth" title over
// a list of the currently connected devices, each with a type glyph, its name, and whatever battery
// level macOS exposes (a single % for mice/keyboards/headsets, or the L/R/Case split for earbuds).
// Modelled on the reference design (Stats' Bluetooth tab) but pared down to match the CPU tab: no
// corner icons, just the title and the device list.
//
// Its own menu-bar item and popover (like CPU / Network), so it never shares space with the other
// panels. The window-visibility reporter tells BluetoothReader when to poll — the read is skipped
// entirely while the popover is closed, since the menu-bar glyph carries no live data.

import SwiftUI
import AppKit

struct BluetoothDetailView: View {
    @ObservedObject var reader: BluetoothReader

    private var info: BluetoothInfo { reader.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bluetooth")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            content

            Divider()

            HStack {
                Button("Refresh") { reader.refresh() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowVisibilityReporter(onChange: { reader.setPanelOpen($0) }))
    }

    @ViewBuilder
    private var content: some View {
        if !info.hasLoaded {
            placeholder("Reading…")
        } else if !info.poweredOn {
            placeholder("Bluetooth is off.")
        } else if info.connected.isEmpty {
            placeholder("No connected devices.")
        } else {
            VStack(spacing: 10) {
                ForEach(info.connected) { device in
                    BluetoothDeviceRow(device: device)
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
    }
}

/// One device row: a type glyph, the device name (with an optional L/R/Case caption for earbuds),
/// and the battery percentage right-aligned — white normally, red when the battery is low, and a
/// dimmed "—" when the device reports no level at all.
private struct BluetoothDeviceRow: View {
    let device: BluetoothDeviceInfo

    private var iconSize: CGFloat { 18 }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbolName)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: iconSize, height: iconSize)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = device.batteryDetail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            batteryValue
        }
    }

    @ViewBuilder
    private var batteryValue: some View {
        if let pct = device.headlineBattery {
            Text("\(pct)%")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(pct <= 20 ? Color.red : Color.white)
        } else {
            Text("—")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}
