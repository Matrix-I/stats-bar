// NetworkInterface.swift — the low-level system reads behind the Network tab, kept free of any UI
// or CoreWLAN so the CoreWLAN / ping / public-IP pieces stay independently testable:
//   • primaryInterface()  — which BSD interface the default route uses (SCDynamicStore)
//   • dnsServers()        — resolver addresses the system is actually using (SCDynamicStore)
//   • serviceName()       — the friendly name ("Wi-Fi") for a BSD interface (SCNetworkService)
//   • addresses()         — MAC + IPv4 + IPv6 + up/running flags for one interface (getifaddrs)
//   • counters()          — 64-bit rx/tx byte totals for one interface (sysctl NET_RT_IFLIST2)
// None of these need root.

import Foundation
import SystemConfiguration

enum NetworkInterface {

    // MARK: Primary interface + DNS (SCDynamicStore)

    /// The BSD name of the interface carrying the default IPv4 route — i.e. the one actually used to
    /// reach the internet. Falls back to the IPv6 primary interface on an IPv6-only link.
    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "StatsBar.net" as CFString, nil, nil) else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let global = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let primary = global["PrimaryInterface"] as? String, !primary.isEmpty {
                return primary
            }
        }
        return nil
    }

    /// Resolver addresses from the live network state (the same list `scutil --dns` reports first),
    /// which reflects DHCP/VPN overrides rather than the static contents of /etc/resolv.conf.
    static func dnsServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "StatsBar.dns" as CFString, nil, nil),
              let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dns["ServerAddresses"] as? [String] else { return [] }
        return servers
    }

    /// Friendly, user-facing name for a BSD interface ("Wi-Fi", "Ethernet", …) as shown in System
    /// Settings, by matching the BSD name against the configured network services. Reading the
    /// preferences is unprivileged.
    static func serviceName(forBSD bsd: String) -> String? {
        guard let prefs = SCPreferencesCreate(nil, "StatsBar.svc" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return nil }
        for svc in services {
            if let iface = SCNetworkServiceGetInterface(svc),
               let name = SCNetworkInterfaceGetBSDName(iface) as String?,
               name == bsd {
                return SCNetworkServiceGetName(svc) as String?
            }
        }
        return nil
    }

    // MARK: Addresses + flags (getifaddrs)

    struct Addresses {
        var mac: String?
        var ipv4: String?
        var ipv6: String?
        var isUp = false
    }

    /// MAC (from the AF_LINK entry), the first non–link-local IPv4/IPv6, and the up/running flags for
    /// one interface, in a single getifaddrs pass. IPv6 link-local (fe80::) addresses are skipped so
    /// the "Local IP" row shows a routable address rather than the always-present link-local one.
    static func addresses(for bsd: String) -> Addresses {
        var out = Addresses()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return out }
        defer { freeifaddrs(head) }

        var ptr = head
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let ifa = cur.pointee
            guard String(cString: ifa.ifa_name) == bsd, let sa = ifa.ifa_addr else { continue }

            let flags = Int32(ifa.ifa_flags)
            if flags & IFF_UP != 0 && flags & IFF_RUNNING != 0 { out.isUp = true }

            switch Int32(sa.pointee.sa_family) {
            case AF_LINK:
                if out.mac == nil, let mac = macString(sa) { out.mac = mac }
            case AF_INET:
                if out.ipv4 == nil { out.ipv4 = ipString(sa, family: AF_INET) }
            case AF_INET6:
                // Skip link-local (fe80::/10) — it's present on every interface and never routable.
                if out.ipv6 == nil, let ip = ipString(sa, family: AF_INET6), !ip.hasPrefix("fe80") {
                    out.ipv6 = ip
                }
            default:
                break
            }
        }
        return out
    }

    /// Formats an AF_LINK sockaddr_dl as "c8:89:f3:e3:c8:8e". Returns nil when the link has no
    /// hardware address (e.g. a loopback or tunnel), so callers just omit the row.
    private static func macString(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        return sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> String? in
            let len = Int(dl.pointee.sdl_alen)
            guard len == 6 else { return nil }
            // The address bytes follow the interface name inside sdl_data; sdl_nlen is that name's
            // length, so the hardware address starts sdl_nlen bytes in.
            let nlen = Int(dl.pointee.sdl_nlen)
            return withUnsafePointer(to: &dl.pointee.sdl_data) { dataPtr in
                dataPtr.withMemoryRebound(to: UInt8.self, capacity: nlen + len) { bytes in
                    (0..<len).map { String(format: "%02x", bytes[nlen + $0]) }.joined(separator: ":")
                }
            }
        }
    }

    /// Numeric presentation form of an AF_INET / AF_INET6 sockaddr via getnameinfo (NI_NUMERICHOST),
    /// which handles both families and strips any IPv6 zone/scope suffix cleanly.
    private static func ipString(_ sa: UnsafeMutablePointer<sockaddr>, family: Int32) -> String? {
        let salen = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size
                                                : MemoryLayout<sockaddr_in6>.size)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, salen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let s = String(cString: host)
        // Drop the "%en0" scope suffix getnameinfo appends to link-local v6 (harmless for others).
        return s.split(separator: "%").first.map(String.init) ?? s
    }

    // MARK: Byte counters (sysctl NET_RT_IFLIST2 → if_data64)

    struct Counters { var rxBytes: UInt64; var txBytes: UInt64 }

    /// 64-bit cumulative rx/tx byte counters for one interface, read from the routing socket's
    /// interface list (NET_RT_IFLIST2 yields `if_data64`). getifaddrs' AF_LINK entry also carries
    /// counters, but only the 32-bit `if_data` variant, which wraps every 4 GB — useless for a
    /// running total on a busy link. Returns nil if the interface isn't found.
    static func counters(for bsd: String) -> Counters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

        var result: Counters?
        buf.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self).pointee
                let msglen = Int(hdr.ifm_msglen)
                if msglen <= 0 { break }
                // if_msghdr and if_msghdr2 share their leading fields, so ifm_type/ifm_msglen read
                // fine from the smaller struct; only RTM_IFINFO2 records are the full if_msghdr2.
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let msg2 = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self).pointee
                    var nameBuf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if if_indextoname(UInt32(msg2.ifm_index), &nameBuf) != nil,
                       String(cString: nameBuf) == bsd {
                        result = Counters(rxBytes: msg2.ifm_data.ifi_ibytes,
                                          txBytes: msg2.ifm_data.ifi_obytes)
                        return
                    }
                }
                offset += msglen
            }
        }
        return result
    }
}
