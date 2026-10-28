import Foundation

/// Sites to offer while the Favorites grid is empty: your most visited sites,
/// topped up with a few common ones.
nonisolated enum FavoriteSuggestions {
    struct Site: Equatable {
        var host: String
        var url: URL
    }

    static let starters = ["youtube.com", "mail.google.com", "github.com", "wikipedia.org"]

    /// `visits` is visit counts by host. Hosts are compared without "www.";
    /// hosts already in Favorites are skipped.
    static func suggestions(visits: [String: Int], existing: Set<String>, limit: Int = 4) -> [Site] {
        var seen = Set(existing.map(Autocomplete.stripWWW))
        var result: [Site] = []
        let visited = visits
            .reduce(into: [String: Int]()) { $0[Autocomplete.stripWWW($1.key.lowercased()), default: 0] += $1.value }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
        for host in visited + starters where result.count < limit && !host.isEmpty && seen.insert(host).inserted {
            if let url = URL(string: "https://\(host)/") { result.append(Site(host: host, url: url)) }
        }
        return result
    }

    /// A URL without its fragment, "www.", or trailing slash, for "is this still the saved page?".
    static func pageKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.fragment = nil
        components.host = components.host.map { Autocomplete.stripWWW($0.lowercased()) }
        if components.scheme == "http" { components.scheme = "https" }
        var key = components.string ?? url.absoluteString
        if key.hasSuffix("/") { key.removeLast() }
        return key
    }
}
