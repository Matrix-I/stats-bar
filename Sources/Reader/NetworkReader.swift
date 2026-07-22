// NetworkReader.swift — the ObservableObject behind the Network tab. It owns one NetworkInfo and
// keeps it fresh from three cadences, all gated on the popover being open so nothing runs (no
// pinging, no outbound lookups) while nobody's looking:
//   • ~1 Hz  local reads   — interface, addresses, DNS, Wi-Fi radio, byte counters → totals + rates
//   • ~3 s   latency ping   — a short ICMP burst to a public host → latency / jitter / reachability
//   • ~5 min public IP      — only if the user leaves "Show public IP" on; the sole outbound call
//
// It also owns the CLLocationManager whose authorization unlocks the Wi-Fi SSID (macOS redacts the
// network name without Location permission), re-reading Wi-Fi the instant permission is granted.
//
// Threading mirrors the other readers: gathers on a background queue, mutates `info` and all the
// bookkeeping only on the main thread. The session throughput baseline is primed at launch so
// "total" means "since the app started", even if the panel is first opened much later.

import Foundation
import Combine
import CoreLocation

final class NetworkReader: NSObject, ObservableObject {
    @Published var info = NetworkInfo()
    @Published var locationStatus: CLAuthorizationStatus = .notDetermined

    private let locationManager = CLLocationManager()

    // All of the following are touched on the main thread only.
    private var isBusy = false
    private var isPinging = false
    private var isFetchingPublicIP = false
    private var panelOpen = false
    private lazy var poll = PollingTimer { [weak self] in self?.tick() }

    // Session throughput: baseline is the counter value at launch/interface-switch; last* + lastSampleTime
    // drive the per-second rate. Keyed by BSD name so plugging into Ethernet resets cleanly.
    private var baselineBSD: String?
    private var baselineRx: UInt64 = 0
    private var baselineTx: UInt64 = 0
    private var lastRx: UInt64 = 0
    private var lastTx: UInt64 = 0
    private var lastSampleTime: DispatchTime?

    private var lastPingAt: DispatchTime?
    private var lastPublicIPAt: DispatchTime?

    private static let pingInterval: TimeInterval = 3
    private static let publicIPInterval: TimeInterval = 300
    private static let pingHost = "1.1.1.1"
    private static let pingHostV6 = "2606:4700:4700::1111"   // Cloudflare — fallback on IPv6-only links

    override init() {
        super.init()
        // Keep the reader's view of the toggle aligned with the view's @AppStorage default (on).
        UserDefaults.standard.register(defaults: ["showPublicIP": true])

        locationManager.delegate = self
        locationStatus = locationManager.authorizationStatus

        primeBaseline()

        // Same rationale as the other readers: MenuBarExtra(.window) builds the view once and just
        // shows/hides it, so .onAppear won't refire — a timer is how we keep the tab live. Ticks are
        // no-ops while the popover is closed.
        poll.schedule(every: 1)
    }

    /// Called by the popover's visibility reporter. Opening kicks an immediate full refresh so the
    /// tab isn't blank on first paint; closing just parks the timer's work.
    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        if open { refresh() }
    }

    /// A full, forced refresh across all three cadences — used on open and by the Refresh button.
    func refresh() {
        fastRefresh(full: true)
        maybePing(force: true)
        maybePublicIP(force: true)
    }

    /// Ask for the Location permission that unlocks the Wi-Fi SSID. Only triggers the system prompt
    /// while the status is undetermined — once the user has decided, macOS won't prompt again, so
    /// we don't try (the UI routes to System Settings instead).
    func requestLocationForSSID() {
        guard locationManager.authorizationStatus == .notDetermined else { return }
        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: Cadences

    private func tick() {
        // Throughput must keep flowing so the menu-bar item shows a live up/down rate even while the
        // popover is closed — so the local read always runs. It's just the counters (a light read)
        // when closed, and the full interface/Wi-Fi/DNS read when the popover is open. The ping and
        // the outbound public-IP lookup only matter inside the popover, so they stay gated.
        fastRefresh(full: panelOpen)
        guard panelOpen else { return }
        maybePing(force: false)
        maybePublicIP(force: false)
    }

    private func primeBaseline() {
        guard let bsd = NetworkInterface.primaryInterface(),
              let c = NetworkInterface.counters(for: bsd) else { return }
        baselineBSD = bsd
        baselineRx = c.rxBytes; baselineTx = c.txBytes
        lastRx = c.rxBytes; lastTx = c.txBytes
        lastSampleTime = DispatchTime.now()
    }

    private struct LocalRead {
        var full: Bool
        var bsd: String?
        var counters: NetworkInterface.Counters?
        // Populated only on a full read (popover open):
        var serviceName: String?
        var addr = NetworkInterface.Addresses()
        var dns: [String] = []
        var wifi: WiFiStatus.Reading?
        var isWiFiPrimary = false
    }

    private func fastRefresh(full: Bool) {
        guard !isBusy else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let r = self.gatherLocal(full: full)
            DispatchQueue.main.async {
                self.applyLocal(r)
                self.isBusy = false
            }
        }
    }

    private func gatherLocal(full: Bool) -> LocalRead {
        var r = LocalRead(full: full)
        // Always needed: the primary interface and its byte counters drive the menu-bar rate.
        r.bsd = NetworkInterface.primaryInterface()
        if let bsd = r.bsd { r.counters = NetworkInterface.counters(for: bsd) }
        // The rest is only shown in the popover, so skip it on the light (closed) path.
        if full {
            if let bsd = r.bsd {
                r.addr = NetworkInterface.addresses(for: bsd)
                r.serviceName = NetworkInterface.serviceName(forBSD: bsd)
            }
            r.dns = NetworkInterface.dnsServers()
            r.wifi = WiFiStatus.read()
            r.isWiFiPrimary = (r.bsd != nil && r.wifi?.interfaceName == r.bsd)
        }
        return r
    }

    private func applyLocal(_ r: LocalRead) {
        var info = self.info      // preserve latency / public-IP / detail fields already populated
        info.interfaceName = r.bsd

        if let c = r.counters, let bsd = r.bsd {
            // Reset the baseline when the interface changed or the counters ran backwards (an
            // interface bounce restarts them at 0), so "total" never goes negative / absurd.
            if baselineBSD != bsd || c.rxBytes < baselineRx || c.txBytes < baselineTx {
                baselineBSD = bsd
                baselineRx = c.rxBytes; baselineTx = c.txBytes
                lastRx = c.rxBytes; lastTx = c.txBytes
                lastSampleTime = DispatchTime.now()
            }
            info.downloadTotal = c.rxBytes - baselineRx
            info.uploadTotal = c.txBytes - baselineTx

            let now = DispatchTime.now()
            if let last = lastSampleTime {
                let dt = Double(now.uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000_000
                if dt > 0.2 {
                    info.downloadRate = Double(c.rxBytes >= lastRx ? c.rxBytes - lastRx : 0) / dt
                    info.uploadRate = Double(c.txBytes >= lastTx ? c.txBytes - lastTx : 0) / dt
                    lastRx = c.rxBytes; lastTx = c.txBytes
                    lastSampleTime = now
                }
            } else {
                lastSampleTime = now; lastRx = c.rxBytes; lastTx = c.txBytes
            }
        }

        // Interface / DNS / Wi-Fi detail only comes in on a full read; on the light (menu-bar-only)
        // path leave the previously-read values untouched rather than blanking them.
        if r.full {
            info.serviceName = r.serviceName
            info.isUp = r.addr.isUp
            info.macAddress = r.addr.mac
            info.localIPv4 = r.addr.ipv4
            info.localIPv6 = r.addr.ipv6
            info.dnsServers = r.dns

            if r.isWiFiPrimary, let w = r.wifi {
                info.isWiFi = true
                info.ssid = w.ssid
                info.rssi = w.rssi
                info.phyMode = w.phyMode
                info.channelNumber = w.channelNumber
                info.channelBand = w.channelBand
                info.channelWidth = w.channelWidth
                info.txRate = w.txRate
            } else {
                info.isWiFi = false
                info.ssid = nil; info.rssi = nil; info.phyMode = nil
                info.channelNumber = nil; info.channelBand = nil; info.channelWidth = nil; info.txRate = nil
            }
        }

        self.info = info
    }

    private func maybePing(force: Bool) {
        guard !isPinging else { return }
        if !force, !elapsed(since: lastPingAt, exceeds: Self.pingInterval) { return }
        isPinging = true
        lastPingAt = DispatchTime.now()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // IPv4 first (the common case). Only if it gets zero replies — offline, or an IPv6-only
            // link where the v4 host has no route — fall back to an IPv6 ping, so latency/reachability
            // still reflect a working IPv6 connection instead of reading dead (primaryInterface()
            // already falls back to the IPv6 global for exactly these links).
            var result = Pinger.ping(host: Self.pingHost)
            if !result.reachable {
                let v6 = Pinger.ping(host: Self.pingHostV6)
                if v6.reachable { result = v6 }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.info.latencyMs = result.latencyMs
                self.info.jitterMs = result.jitterMs
                self.info.internetReachable = result.reachable
                self.isPinging = false
            }
        }
    }

    private func maybePublicIP(force: Bool) {
        guard UserDefaults.standard.bool(forKey: "showPublicIP") else {
            // Toggle is off: drop any previously-fetched values so the rows disappear.
            if info.publicIPv4 != nil || info.publicIPv6 != nil || info.countryCode != nil || info.publicIPError {
                info.publicIPv4 = nil; info.publicIPv6 = nil; info.countryCode = nil; info.publicIPError = false
            }
            lastPublicIPAt = nil
            return
        }
        guard !isFetchingPublicIP else { return }
        if !force, !elapsed(since: lastPublicIPAt, exceeds: Self.publicIPInterval) { return }
        isFetchingPublicIP = true
        lastPublicIPAt = DispatchTime.now()
        PublicIP.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.info.publicIPv4 = result.ipv4
                self.info.publicIPv6 = result.ipv6
                self.info.countryCode = result.countryCode
                self.info.publicIPError = result.failed
                self.isFetchingPublicIP = false
            }
        }
    }

    /// True when `mark` is nil or more than `seconds` in the past — the min-interval gate for the
    /// ping / public-IP cadences.
    private func elapsed(since mark: DispatchTime?, exceeds seconds: TimeInterval) -> Bool {
        guard let mark else { return true }
        return Double(DispatchTime.now().uptimeNanoseconds - mark.uptimeNanoseconds) / 1_000_000_000 >= seconds
    }
}

extension NetworkReader: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationStatus = manager.authorizationStatus
        // Re-read Wi-Fi right away so the SSID shows the moment permission is granted.
        if panelOpen { fastRefresh(full: true) }
    }
}
