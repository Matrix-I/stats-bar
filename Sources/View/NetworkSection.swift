// NetworkSection.swift — the Network tab's contents, laid out to mirror the reference design:
// throughput totals + link/internet status + latency/jitter up top, an INTERFACE block (interface
// name, MAC, Wi-Fi radio details, DNS), and an ADDRESS block (local + optional public IP with a
// country flag). All fields come from a single NetworkReader; anything not yet read is simply
// omitted rather than shown blank.

import SwiftUI
import AppKit

/// The Network menu-bar item's popover: the full network readout plus a pinned Refresh/Quit footer.
/// Separate from the battery popover — its own menu-bar item, its own window — so the two panels
/// never share space. The window-visibility reporter tells NetworkReader when to run its heavier
/// work (ping + public-IP lookup); the light throughput read keeps running regardless so the
/// menu-bar rate stays live even while this popover is closed.
struct NetworkDetailView: View {
    @ObservedObject var reader: NetworkReader

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NetworkSection(reader: reader)

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
}

struct NetworkSection: View {
    @ObservedObject var reader: NetworkReader
    @AppStorage("showPublicIP") private var showPublicIP = true

    private var info: NetworkInfo { reader.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("🌐 Network").font(.headline)
                Spacer()
                if let svc = info.serviceName ?? info.interfaceName {
                    Text(svc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if info.interfaceName == nil {
                Text("No active network connection.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                NetRateHeader(downloadRate: info.downloadRate, uploadRate: info.uploadRate)
                Divider()
                overview
                interfaceBlock
                addressBlock
                controls
            }
        }
    }

    // MARK: Overview (throughput + status + latency)

    @ViewBuilder
    private var overview: some View {
        VStack(spacing: 6) {
            // Live rate is shown prominently in NetRateHeader above, so these rows are just the
            // cumulative session totals.
            NetTotalRow(color: .red, label: "Total upload", value: fmtBytes(info.uploadTotal))
            NetTotalRow(color: .blue, label: "Total download", value: fmtBytes(info.downloadTotal))

            NetBadgeRow(label: "Status", up: info.isUp)
            NetBadgeRow(label: "Internet connection", up: info.internetReachable)

            InfoRow(label: "Latency",
                    value: info.latencyMs.map { String(format: "%.2f ms", $0) } ?? "—")
            InfoRow(label: "Jitter",
                    value: info.jitterMs.map { String(format: "%.2f ms", $0) } ?? "—")
        }
    }

    // MARK: Interface block

    @ViewBuilder
    private var interfaceBlock: some View {
        SectionCaption("INTERFACE")
        VStack(spacing: 6) {
            InfoRow(label: "Interface", value: interfaceValue)
            if let mac = info.macAddress {
                InfoRow(label: "Physical address", value: mac)
            }
            if info.isWiFi {
                networkNameRow
                if let phy = info.phyMode { InfoRow(label: "Standard", value: phy) }
                if let ch = channelValue { InfoRow(label: "Channel", value: ch) }
                if let tx = info.txRate { InfoRow(label: "Speed", value: String(format: "%.0f Mbps", tx)) }
            }
            if !info.dnsServers.isEmpty {
                NetDNSRow(servers: info.dnsServers)
            }
        }
    }

    private var interfaceValue: String {
        switch (info.serviceName, info.interfaceName) {
        case let (svc?, bsd?): return "\(svc) (\(bsd))"
        case let (svc?, nil):  return svc
        case let (nil, bsd?):  return bsd
        default:               return "—"
        }
    }

    private var channelValue: String? {
        guard let n = info.channelNumber else { return nil }
        let extras = [info.channelBand, info.channelWidth].compactMap { $0 }.joined(separator: ", ")
        return extras.isEmpty ? "\(n)" : "\(n) (\(extras))"
    }

    /// "Lupin (-43)" when the SSID is readable; just the signal when only RSSI is available; and a
    /// tap-to-grant prompt when Location hasn't been authorized (macOS hides the SSID without it).
    @ViewBuilder
    private var networkNameRow: some View {
        if let ssid = info.ssid {
            let rssi = info.rssi.map { " (\($0))" } ?? ""
            InfoRow(label: "Network", value: ssid + rssi)
        } else if needsLocationForSSID {
            let decided = reader.locationStatus != .notDetermined  // already asked once
            HStack {
                Text("Network")
                Spacer()
                Button {
                    if decided {
                        // The OS only prompts once; once the user has decided, re-requesting is a
                        // no-op, so send them to System Settings to flip it on instead.
                        openLocationSettings()
                    } else {
                        reader.requestLocationForSSID()   // the single system prompt
                    }
                } label: {
                    Text(decided ? "Enable in Settings ›" : "Show name (allow Location)")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .font(.system(size: 12))
        } else if let rssi = info.rssi {
            InfoRow(label: "Network", value: "signal \(rssi) dBm")
        }
    }

    private var needsLocationForSSID: Bool {
        reader.locationStatus != .authorized && reader.locationStatus != .authorizedAlways
    }

    private func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Address block

    @ViewBuilder
    private var addressBlock: some View {
        SectionCaption("ADDRESS")
        VStack(spacing: 6) {
            if let v4 = info.localIPv4 { InfoRow(label: "Local IP", value: v4) }
            if let v6 = info.localIPv6 { InfoRow(label: "Local IPv6", value: v6) }

            if showPublicIP {
                let flag = info.countryCode.map { " " + flagEmoji($0) } ?? ""
                if let p4 = info.publicIPv4 { InfoRow(label: "Public IP", value: p4 + flag) }
                if let p6 = info.publicIPv6 { InfoRow(label: "Public IP (v6)", value: p6 + flag) }
                if info.publicIPv4 == nil && info.publicIPv6 == nil {
                    InfoRow(label: "Public IP", value: info.publicIPError ? "unavailable" : "looking up…")
                }
            }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        Divider()
        // No explicit onChange: NetworkReader re-reads this toggle on its ~1 Hz tick, so flipping it
        // fetches (or clears) the public IP within a second while the popover is open.
        Toggle("Show public IP (uses an online lookup)", isOn: $showPublicIP)
            .font(.caption)
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

// MARK: - Small building blocks

/// The prominent live-rate header at the top of the tab: two big numbers (Download in blue, Upload
/// in red) with their unit and a colour-keyed label, matching the reference design.
private struct NetRateHeader: View {
    let downloadRate: Double
    let uploadRate: Double
    var body: some View {
        HStack(spacing: 0) {
            NetRatePillar(color: .blue, label: "Download", rate: downloadRate)
            NetRatePillar(color: .red, label: "Upload", rate: uploadRate)
        }
        .padding(.top, 16)
        .padding(.bottom, 20)
    }
}

private struct NetRatePillar: View {
    let color: Color
    let label: String
    let rate: Double
    var body: some View {
        let parts = fmtRateParts(rate)
        VStack(spacing: 5) {
            // Fixed-width value (right-aligned) and unit (left-aligned) columns so the number/unit
            // junction stays put as the rate changes — otherwise the centred content re-centres on
            // every update and the whole block visibly jitters left/right. monospacedDigit keeps the
            // digits themselves equal-width too.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(parts.value)
                    .font(.system(size: 26, weight: .regular))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
                Text(parts.unit)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
            }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
                Text(label).font(.system(size: 12)).foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A green "UP" / red "DOWN" pill, matching the reference status chips.
private struct NetStatusBadge: View {
    let up: Bool
    var body: some View {
        Text(up ? "UP" : "DOWN")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(up ? Color.green : Color.red))
    }
}

private struct NetBadgeRow: View {
    let label: String
    let up: Bool
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            NetStatusBadge(up: up)
        }
        .font(.system(size: 12))
    }
}

/// A throughput total row: a colour-keyed square (red = upload, blue = download), the label, and the
/// cumulative session total. The live rate lives in NetRateHeader, not here.
private struct NetTotalRow: View {
    let color: Color
    let label: String
    let value: String
    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

/// The DNS row: label + first server on the top line, any further resolvers stacked right-aligned
/// below (a machine on a VPN or dual-stack link commonly has several).
private struct NetDNSRow: View {
    let servers: [String]
    var body: some View {
        HStack(alignment: .top) {
            Text("DNS Server")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                // Index-stable id: ServerAddresses can list the same resolver twice (VPN + base
                // service pushing identical IPs), and id: \.self would collide on the duplicate.
                ForEach(Array(servers.enumerated()), id: \.offset) { _, s in
                    Text(s).fontWeight(.medium).monospacedDigit().lineLimit(1)
                }
            }
        }
        .font(.system(size: 12))
    }
}
