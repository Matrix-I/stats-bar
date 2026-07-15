// IOSDeviceSection.swift — the iPhone/iPad block in the detail panel: one row per connected
// device, plus the section wrapper that handles the tools-missing / no-device / list states.

import SwiftUI

struct IOSDeviceRow: View {
    let device: IOSDeviceInfo
    @State private var showFullDetails = false

    /// Time-only for a reading captured today; date + time once it's from an earlier day, so a
    /// health figure that is actually days old isn't misread as a same-day reading.
    private static func readingStamp(_ at: Date) -> String {
        Calendar.current.isDateInToday(at)
            ? at.formatted(date: .omitted, time: .shortened)
            : at.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(device.name).font(.caption).fontWeight(.semibold).lineLimit(1)
                Spacer()
                let sub = [device.model.isEmpty ? nil : device.model,
                           device.iosVersion.isEmpty ? nil : "iOS \(device.iosVersion)"]
                    .compactMap { $0 }.joined(separator: " · ")
                if !sub.isEmpty {
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if device.isNetwork {
                Text("📶 Connected over Wi-Fi (no USB data connection)")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if device.isStale {
                Text("⟳ last known data — connection reconnecting")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if device.isLocked {
                // Detailed health needs the diagnostics relay, which iOS refuses while the device
                // is at the passcode lock screen (the common case) — occasionally also when another
                // app is holding the relay. Charge may still be live. Guide the user to unlock
                // without asserting the exact cause; it refreshes on its own once readable again.
                if device.maxCapacity != nil, let at = device.capturedAt {
                    Text("🔒 Battery health from last reading (\(Self.readingStamp(at))) — unlock the iPhone to refresh.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("🔒 Unlock the iPhone to read battery health.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let err = device.errorMessage {
                Text(err).font(.caption2).foregroundStyle(.red)
            } else if device.chargePercent == nil && device.healthPercent == nil {
                // Only surface the generic warning when it isn't already explained by the lock note.
                if !device.isLocked {
                    Text("⚠ Couldn't read health data — unlock the device + Trust, then tap Refresh.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else {
                if let cp = device.chargePercent {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Charge").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f%%", cp)).font(.caption).fontWeight(.medium).monospacedDigit()
                    }
                    BarView(pct: cp, color: .blue)
                }
                if let hp = device.healthPercent {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Health").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f%%", hp))
                            .font(.caption).fontWeight(.medium).monospacedDigit()
                            .foregroundStyle(healthColor(hp))
                    }
                    BarView(pct: hp, color: healthColor(hp))
                }
                if let max = device.maxCapacity {
                    InfoRow(label: "Full charge capacity", value: "\(max) mAh")
                }
                if let design = device.designCapacity {
                    InfoRow(label: "Design capacity", value: "\(design) mAh")
                }
                if let cc = device.cycleCount {
                    InfoRow(label: "Cycle count", value: "\(cc)")
                }

                ZStack {
                    Divider()
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showFullDetails.toggle()
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(showFullDetails ? Color.white : Color.secondary)
                                .padding(4)
                                .background(
                                    Circle().fill(showFullDetails ? Color.accentColor : Color.secondary.opacity(0.15))
                                )
                        }
                        .buttonStyle(.plain)
                        .help(showFullDetails ? "Show less" : "Show more")
                    }
                }

                if showFullDetails {
                    if let t = device.temperatureC {
                        InfoRow(label: "Temperature", value: String(format: "%.1f °C", t))
                    }
                    if let v = device.voltageV {
                        InfoRow(label: "Voltage", value: String(format: "%.2f V", v))
                    }
                    if device.isCharging, let w = device.watts, w > 0.05 {
                        InfoRow(label: "Charging with", value: String(format: "%.1f W", w))
                    }
                    if device.externalConnected {
                        InfoRow(label: "Status",
                                value: device.isCharging ? "Charging"
                                    : (device.fullyCharged ? "Fully charged" : "Plugged in, not charging"))
                    }
                    if !device.serial.isEmpty {
                        InfoRow(label: "Serial", value: device.serial)
                    }
                }
            }
        }
    }
}

struct IOSDevicesSection: View {
    @ObservedObject var reader: IOSDeviceReader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📱 iPhone / iPad (USB / Wi-Fi)").font(.caption).foregroundStyle(.secondary)

            if reader.toolsMissing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Missing libimobiledevice.").font(.caption2).foregroundStyle(.orange)
                    Text("brew install libimobiledevice")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else if let status = reader.statusMessage {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            } else if reader.devices.isEmpty {
                Text("No devices connected.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                // No ScrollView here: SwiftUI's ScrollView has no well-defined ideal height inside
                // an auto-sizing MenuBarExtra(.window) popover, so it was rendering at ~0 height —
                // the section looked empty even though `devices` held real data. A plain VStack
                // always has a proper intrinsic size, so let the popover grow to fit instead.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(reader.devices) { device in
                        IOSDeviceRow(device: device)
                        if device.id != reader.devices.last?.id { Divider() }
                    }
                }
            }
        }
    }
}
