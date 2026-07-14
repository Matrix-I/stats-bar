// AndroidDeviceSection.swift — the Android block in the detail panel: one row per connected
// device, plus the section wrapper that handles the tools-missing / no-device / list states.

import SwiftUI

struct AndroidDeviceRow: View {
    let device: AndroidDeviceInfo
    @State private var showFullDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(device.name).font(.caption).fontWeight(.semibold).lineLimit(1)
                Spacer()
                let sub = [device.manufacturer.isEmpty ? nil : device.manufacturer,
                           device.androidVersion.isEmpty ? nil : "Android \(device.androidVersion)"]
                    .compactMap { $0 }.joined(separator: " · ")
                if !sub.isEmpty {
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if device.isStale {
                Text("⟳ last known data — USB connection reconnecting")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if let err = device.errorMessage {
                Text(err).font(.caption2).foregroundStyle(.orange)
            } else {
                if let level = device.levelPercent {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Charge").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(level)%").font(.caption).fontWeight(.medium).monospacedDigit()
                    }
                    BarView(pct: Double(level), color: .blue)
                }
                if let hp = device.healthPercent {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Health (vs design)").font(.caption2).foregroundStyle(.secondary)
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
                    if let health = device.healthText {
                        InfoRow(label: "Health status", value: health)
                    }
                    if let t = device.temperatureC {
                        InfoRow(label: "Temperature", value: String(format: "%.1f °C", t))
                    }
                    if let v = device.voltageV {
                        InfoRow(label: "Voltage", value: String(format: "%.2f V", v))
                    }
                    if !device.technology.isEmpty {
                        InfoRow(label: "Technology", value: device.technology)
                    }
                    if device.isCharging, let w = device.maxChargingWatts {
                        InfoRow(label: "Max charging power", value: String(format: "%.1f W", w))
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

struct AndroidDevicesSection: View {
    @ObservedObject var reader: AndroidDeviceReader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🤖 Android (USB)").font(.caption).foregroundStyle(.secondary)

            if reader.toolsMissing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Missing adb.").font(.caption2).foregroundStyle(.orange)
                    Text("brew install --cask android-platform-tools")
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
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(reader.devices) { device in
                        AndroidDeviceRow(device: device)
                        if device.id != reader.devices.last?.id { Divider() }
                    }
                }
            }
        }
    }
}
