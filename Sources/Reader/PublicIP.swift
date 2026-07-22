// PublicIP.swift — looks up the machine's public-facing IP addresses and country by asking a couple
// of small public "what is my IP" endpoints. This is the ONE part of the Network tab that reaches
// out to third-party servers, so it only runs when the user has left the "Show public IP" toggle on
// (see NetworkReader) — everything else in the tab is read locally.
//
// Endpoints (all plain-text, no API key):
//   • https://api.ipify.org   → IPv4 (A-only host)
//   • https://api6.ipify.org  → IPv6 (AAAA-only host; simply fails on IPv4-only links)
//   • https://ipinfo.io/country → ISO country code for the flag
// Each is independent, so a link with no IPv6 still shows the IPv4 + country.

import Foundation

enum PublicIP {

    struct Result {
        var ipv4: String?
        var ipv6: String?
        var countryCode: String?
        var failed: Bool          // no address came back at all (offline / endpoints unreachable)
    }

    /// Fetches all three values concurrently and calls back on a background queue. `timeout` bounds
    /// each request so a hung endpoint can't wedge the reader.
    static func fetch(timeout: TimeInterval = 5, completion: @escaping (Result) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        let group = DispatchGroup()
        var ipv4: String?, ipv6: String?, country: String?

        func text(_ url: String, _ store: @escaping (String) -> Void) {
            guard let u = URL(string: url) else { return }
            group.enter()
            session.dataTask(with: u) { data, _, _ in
                defer { group.leave() }
                guard let data, let s = String(data: data, encoding: .utf8) else { return }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { store(trimmed) }
            }.resume()
        }

        text("https://api.ipify.org") { ipv4 = $0 }
        text("https://api6.ipify.org") { ipv6 = $0 }
        text("https://ipinfo.io/country") { country = $0.uppercased() }

        // Let the three tasks finish, then tear the session down. Not strictly a leak (a
        // completion-handler session with no delegate is reclaimed by ARC once its tasks end), but
        // invalidating is the documented lifecycle and makes explicit that this per-fetch session,
        // built fresh each call, is never reused.
        session.finishTasksAndInvalidate()

        group.notify(queue: .global(qos: .utility)) {
            // Guard against a garbage body being mistaken for a country code (e.g. an HTML error page).
            let cc = (country?.count == 2 && country!.allSatisfy { $0.isASCII && $0.isLetter }) ? country : nil
            completion(Result(ipv4: ipv4, ipv6: ipv6, countryCode: cc,
                              failed: ipv4 == nil && ipv6 == nil))
        }
    }
}
