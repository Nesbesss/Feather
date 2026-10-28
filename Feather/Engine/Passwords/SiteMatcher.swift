import Foundation

/// Decides which saved logins belong to a page. A login is offered on its
/// exact host first, then on other hosts of the same site (registrable domain),
/// so a password saved on accounts.example.com shows up on www.example.com.
nonisolated enum SiteMatcher {
    /// Second-level labels used under two-letter country TLDs (example.co.uk, example.com.au).
    private static let secondLevelLabels: Set<String> = [
        "co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go", "mil", "nic", "ltd", "plc", "sch", "gob",
    ]

    /// Approximate eTLD+1: "a.b.example.co.uk" → "example.co.uk". IP addresses and single labels are returned as is.
    static func registrableDomain(_ host: String) -> String {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = host.split(separator: ".").map(String.init)
        let isIPv4 = labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }
        guard labels.count > 2, !isIPv4, !host.contains(":") else { return host }
        let tld = labels[labels.count - 1], second = labels[labels.count - 2]
        let keep = tld.count == 2 && secondLevelLabels.contains(second) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// 0 for the exact host, 1 for the same site, nil when the login doesn't belong to the page.
    static func rank(savedHost: String, pageHost: String) -> Int? {
        let saved = savedHost.lowercased(), page = pageHost.lowercased()
        if saved == page { return 0 }
        return registrableDomain(saved) == registrableDomain(page) ? 1 : nil
    }
}
