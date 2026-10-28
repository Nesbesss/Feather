import Foundation

/// Converts a hosts-format blocklist into WebKit content rules. Blocked
/// requests never load, which saves the memory and CPU ads and trackers cost.
nonisolated enum BlocklistConverter {
    /// WebKit rejects rule lists above 150,000 rules.
    static let maxRules = 149_000

    private static let ignoredHosts: Set<String> = [
        "localhost", "localhost.localdomain", "local", "broadcasthost", "0.0.0.0",
        "ip6-localhost", "ip6-loopback", "ip6-localnet", "ip6-mcastprefix",
        "ip6-allnodes", "ip6-allrouters", "ip6-allhosts",
    ]

    /// Unique domains from `0.0.0.0 example.com` / `127.0.0.1 example.com` lines.
    /// Subdomains of a listed domain are dropped, since each rule already covers subdomains.
    static func domains(fromHosts text: String) -> [String] {
        var all = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let fields = content.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "0.0.0.0" || fields[0] == "127.0.0.1" else { continue }
            for field in fields.dropFirst() {
                let host = field.lowercased()
                guard !ignoredHosts.contains(host), host.contains("."),
                      host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") })
                else { continue }
                all.insert(host)
            }
        }
        return all.filter { !hasListedParent($0, in: all) }.sorted()
    }

    /// `^[^:]+://+([^:/]+\.)?example\.com[:/]`: the domain or any subdomain, any scheme.
    static func urlFilter(for domain: String) -> String {
        let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
        return "^[^:]+://+([^:/]+\\.)?\(escaped)[:/]"
    }

    /// Rule JSON blocking third-party loads from the domains. Third-party only, so
    /// visiting a listed site directly still works.
    static func networkRules(for domains: [String]) throws -> Data {
        let rules = domains.prefix(maxRules).map { domain -> [String: Any] in
            ["trigger": ["url-filter": urlFilter(for: domain), "load-type": ["third-party"]],
             "action": ["type": "block"]]
        }
        return try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
    }

    private static func hasListedParent(_ host: String, in all: Set<String>) -> Bool {
        var rest = Substring(host)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if rest.contains("."), all.contains(String(rest)) { return true }
        }
        return false
    }
}
