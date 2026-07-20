// AndroidDeviceSection.swift — the Android block in the detail panel: one row per connected
// device, plus the section wrapper that handles the tools-missing / no-device / list states.

import SwiftUI

struct AndroidDeviceRow: View {
    let device: AndroidDeviceInfo
    /// Driven by the section-level toggle sitting on the "Android" title line, so every device row
    /// expands/collapses together (mirrors the "Power (live)" section header).
    let showFullDetails: Bool

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
                // Same block layout, fonts, and 12 pt group spacing as the Mac / iPhone battery
                // cards, so all three read identically: each charge/health readout is its own tight
                // 4 pt block, and the blocks are separated by the wider 12 pt group gap.
                VStack(alignment: .leading, spacing: 12) {
                    if let level = device.levelPercent {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Current charge").font(.system(size: 14)).foregroundStyle(.white)
                                Spacer()
                                Text("\(level)%").font(.caption).fontWeight(.medium).monospacedDigit()
                            }
                            BarView(pct: Double(level), color: .blue)
                            if let cur = device.currentCapacity, let max = device.maxCapacity {
                                Text("\(cur) / \(max) mAh")
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    if let mc = device.maximumCapacityPercent {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Maximum Capacity").font(.system(size: 14)).foregroundStyle(.white)
                                Spacer()
                                Text(String(format: "%.0f%%", mc))
                                    .font(.caption).fontWeight(.medium).monospacedDigit()
                                    .foregroundStyle(healthColor(mc))
                            }
                            BarView(pct: mc, color: healthColor(mc))
                            if let max = device.maxCapacity, let design = device.designCapacity {
                                Text("\(max) / \(design) mAh")
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    VStack(spacing: 6) {
                        if let max = device.maxCapacity {
                            InfoRow(label: "Full charge capacity", value: "\(max) mAh")
                        }
                        if let design = device.designCapacity {
                            InfoRow(label: "Design capacity", value: "\(design) mAh")
                        }
                        if let cc = device.cycleCount {
                            InfoRow(label: "Cycle count", value: "\(cc)")
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
                .padding(.top, 8)
            }
        }
    }
}

// The section wrapper (AndroidDevicesSection) was inlined into BatteryDetailView as the
// `androidSection` computed property — same reasoning as the iPhone section. Only the row remains here.
