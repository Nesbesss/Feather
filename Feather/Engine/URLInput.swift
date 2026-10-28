import Foundation

/// Turns what the user typed into a URL or a search, the way Safari's
/// `_goToUnifiedFieldURLWithWindowPolicy:` does: bare hosts get HTTPS first with
/// HTTP as a fallback, local hosts get HTTP, and anything else is a search.
nonisolated enum URLInput {
    enum Resolution: Equatable {
        case url(URL, fallbacks: [URL])
        case search(String)
    }

    /// Schemes the browser opens itself; other known schemes go to the system.
    static let webSchemes: Set<String> = ["http", "https", "file", "about"]
    static let systemSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio", "maps"]

    static func resolve(_ raw: String) -> Resolution? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let scheme = explicitScheme(of: text) {
            if webSchemes.contains(scheme) || systemSchemes.contains(scheme),
               let url = URL(string: text) ?? URL(string: encodeSpaces(text)) {
                return .url(url, fallbacks: [])
            }
            return .search(text)  // javascript:, data:, unknown schemes
        }

        if text.contains(where: \.isWhitespace) { return .search(text) }

        let host = hostPart(of: text)
        if host == "localhost" || host.hasSuffix(".localhost") || isIPv4(host) {
            return URL(string: "http://" + text).map { .url($0, fallbacks: []) } ?? .search(text)
        }
        if looksLikeDomain(host), let https = URL(string: "https://" + text) {
            let fallback = URL(string: "http://" + text).map { [$0] } ?? []
            return .url(https, fallbacks: fallback)
        }
        return .search(text)
    }

    static func searchURL(for query: String, template: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// Lowercased scheme when the text starts with `scheme:` and is not `host:port`.
    static func explicitScheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return nil }
        let rest = text[text.index(after: colon)...]
        if !rest.hasPrefix("//"), let digit = rest.first, digit.isNumber { return nil }  // example.com:8080
        return scheme.lowercased()
    }

    static func hostPart(of text: String) -> String {
        let authority = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let host = authority.split(separator: "@").last.map(String.init) ?? String(authority)
        return (host.split(separator: ":").first.map(String.init) ?? host).lowercased()
    }

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    static func looksLikeDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last else { return false }
        let validLabels = labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
        let validTLD = tld.hasPrefix("xn--") || (tld.count >= 2 && tld.allSatisfy(\.isLetter))
        return validLabels && validTLD
    }

    private static func encodeSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "%20")
    }
}
