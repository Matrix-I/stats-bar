// Pinger.swift — measures internet latency and jitter with a small burst of ICMP echo requests.
//
// Uses an *unprivileged* ICMP socket: socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP) for IPv4, and
// socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6) for IPv6. On Darwin this datagram flavour lets a
// normal user process send/receive ICMP echo without the raw-socket root requirement (it's how
// ping(8)/ping6 work without setuid). The kernel rewrites the echo identifier to the socket's port
// and only delivers matching replies back to us, so we match on the sequence number we set (the
// identifier is not ours to rely on). Latency is the mean RTT of the burst; jitter is the standard
// deviation. The address family is chosen from the host string, so callers can fall back from an
// IPv4 host to an IPv6 one on an IPv6-only link.
//
// This is deliberately synchronous and meant to run on a background queue (see NetworkReader): one
// burst blocks for at most count × timeout.

import Foundation

enum Pinger {

    struct Result {
        var samples: [Double]      // per-reply RTT in ms
        var latencyMs: Double?     // mean
        var jitterMs: Double?      // population standard deviation
        var reachable: Bool        // at least one reply came back
    }

    private static let unreachable = Result(samples: [], latencyMs: nil, jitterMs: nil, reachable: false)

    /// Pings `host` (an IPv4 dotted-quad or an IPv6 literal) `count` times and summarises the RTTs.
    static func ping(host: String, count: Int = 5, timeout: TimeInterval = 1.0) -> Result {
        let identifier = UInt16(truncatingIfNeeded: getpid())

        var v4 = sockaddr_in()
        v4.sin_family = sa_family_t(AF_INET)
        if inet_pton(AF_INET, host, &v4.sin_addr) == 1 {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
            guard fd >= 0 else { return unreachable }
            defer { close(fd) }
            return burst(count: count) { seq in
                onePingV4(fd: fd, addr: v4, identifier: identifier, seq: seq, timeout: timeout)
            }
        }

        var v6 = sockaddr_in6()
        v6.sin6_family = sa_family_t(AF_INET6)
        if inet_pton(AF_INET6, host, &v6.sin6_addr) == 1 {
            let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
            guard fd >= 0 else { return unreachable }
            defer { close(fd) }
            return burst(count: count) { seq in
                onePingV6(fd: fd, addr: v6, identifier: identifier, seq: seq, timeout: timeout)
            }
        }

        return unreachable
    }

    /// Runs `count` pings (spacing them slightly so replies don't bunch up and understate jitter) via
    /// the family-specific `onePing`, and summarises the collected RTTs.
    private static func burst(count: Int, onePing: (UInt16) -> Double?) -> Result {
        var samples: [Double] = []
        for seq in 0..<count {
            if let rtt = onePing(UInt16(truncatingIfNeeded: seq)) { samples.append(rtt) }
            if seq < count - 1 { Thread.sleep(forTimeInterval: 0.12) }
        }
        let mean = samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count)
        var jitter: Double?
        if let mean, samples.count > 1 {
            let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(samples.count)
            jitter = variance.squareRoot()
        }
        return Result(samples: samples, latencyMs: mean, jitterMs: jitter, reachable: !samples.isEmpty)
    }

    /// Sends one IPv4 echo request and waits (up to `timeout`) for the matching reply, returning the
    /// RTT in milliseconds, or nil on timeout / error.
    private static func onePingV4(fd: Int32, addr: sockaddr_in, identifier: UInt16,
                                  seq: UInt16, timeout: TimeInterval) -> Double? {
        var a = addr
        var packet = echoPacket(type: 8, identifier: identifier, seq: seq, computeChecksum: true)  // ICMP_ECHO
        let sent = packet.withUnsafeMutableBytes { raw -> Int in
            withUnsafePointer(to: &a) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                    sendto(fd, raw.baseAddress, raw.count, 0, saptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return nil }
        return awaitReply(fd: fd, seq: seq, timeout: timeout, replyType: 0) { buf, n in
            // The reply may or may not carry a leading IPv4 header depending on the socket flavour,
            // so locate the ICMP header by skipping the IP header only when one is present.
            var off = 0
            if (buf[0] >> 4) == 4 { off = Int(buf[0] & 0x0f) * 4 }
            return n >= off + 8 ? off : nil
        }
    }

    /// The IPv6 counterpart. ICMPv6 uses echo type 128 (reply 129), and the kernel computes the
    /// ICMPv6 checksum for a SOCK_DGRAM socket (it needs the source address from the pseudo-header),
    /// so we leave the checksum field zero. A datagram ICMPv6 socket delivers the ICMPv6 message with
    /// no IPv6 header prepended, so the header starts at offset 0.
    private static func onePingV6(fd: Int32, addr: sockaddr_in6, identifier: UInt16,
                                  seq: UInt16, timeout: TimeInterval) -> Double? {
        var a = addr
        var packet = echoPacket(type: 128, identifier: identifier, seq: seq, computeChecksum: false)  // ICMP6_ECHO_REQUEST
        let sent = packet.withUnsafeMutableBytes { raw -> Int in
            withUnsafePointer(to: &a) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                    sendto(fd, raw.baseAddress, raw.count, 0, saptr, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        guard sent > 0 else { return nil }
        return awaitReply(fd: fd, seq: seq, timeout: timeout, replyType: 129) { _, n in n >= 8 ? 0 : nil }
    }

    /// Shared receive loop: polls `fd` until `timeout`, and for each datagram calls `headerOffset` to
    /// locate the ICMP header (returning nil to skip a too-short packet). Returns the RTT once a reply
    /// of `replyType` carrying our `seq` arrives, or nil on timeout. `start` is captured at call time.
    private static func awaitReply(fd: Int32, seq: UInt16, timeout: TimeInterval, replyType: UInt8,
                                   headerOffset: ([UInt8], Int) -> Int?) -> Double? {
        let start = DispatchTime.now()
        let deadline = start.uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var recvBuf = [UInt8](repeating: 0, count: 1024)
        while true {
            let remainingNs = Int64(deadline) - Int64(DispatchTime.now().uptimeNanoseconds)
            if remainingNs <= 0 { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(remainingNs / 1_000_000))
            guard pr > 0 else { return nil }   // 0 = timeout, <0 = error

            let n = recv(fd, &recvBuf, recvBuf.count, 0)
            guard n > 0, let off = headerOffset(recvBuf, n) else { if n > 0 { continue } else { return nil } }
            let type = recvBuf[off]
            let replySeq = (UInt16(recvBuf[off + 6]) << 8) | UInt16(recvBuf[off + 7])
            // Match our sequence so a straggler from an earlier ping can't be mistaken for this one
            // (which would report an artificially low RTT).
            guard type == replyType, replySeq == seq else { continue }
            let rttNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            return Double(rttNs) / 1_000_000.0
        }
    }

    /// Builds an 8-byte ICMP echo-request header + a short zero payload. `type` is 8 (ICMP_ECHO) for
    /// IPv4 or 128 (ICMP6_ECHO_REQUEST) for IPv6. The IPv4 checksum is filled in here; for IPv6 the
    /// kernel computes it, so `computeChecksum` is false and the field stays zero.
    private static func echoPacket(type: UInt8, identifier: UInt16, seq: UInt16,
                                   computeChecksum: Bool) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 16)   // 8-byte header + 8-byte payload
        p[0] = type
        p[1] = 0                                    // code
        p[2] = 0; p[3] = 0                          // checksum
        p[4] = UInt8(identifier >> 8); p[5] = UInt8(identifier & 0xff)
        p[6] = UInt8(seq >> 8);        p[7] = UInt8(seq & 0xff)
        if computeChecksum {
            let ck = checksum(p)
            p[2] = UInt8(ck >> 8); p[3] = UInt8(ck & 0xff)
        }
        return p
    }

    /// Standard internet checksum (RFC 1071): one's-complement sum of the 16-bit big-endian words.
    private static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count {
            sum += (UInt32(data[i]) << 8) | UInt32(data[i + 1])
            i += 2
        }
        if i < data.count { sum += UInt32(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(~sum & 0xffff)
    }
}
