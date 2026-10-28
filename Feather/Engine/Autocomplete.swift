import Foundation

/// Inline address completion: typing "yo" completes to "youtube.com" when you
/// visit it, the way Safari's address field does.
nonisolated enum Autocomplete {
    struct Candidate: Sendable {
        var host: String
        /// Visit count or similar; higher wins.
        var score: Double
    }

    /// The host to complete `typed` to, or nil. Only bare host prefixes complete:
    /// nothing with spaces, a path, or a scheme.
    static func completion(for typed: String, candidates: [Candidate]) -> String? {
        let text = typed.lowercased()
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" }) else { return nil }
        var best: Candidate?
        for candidate in candidates {
            let host = stripWWW(candidate.host.lowercased())
            guard host.count > text.count, host.hasPrefix(text) else { continue }
            if let current = best {
                let currentHost = stripWWW(current.host.lowercased())
                if candidate.score < current.score || (candidate.score == current.score && host.count >= currentHost.count) {
                    continue
                }
            }
            best = Candidate(host: host, score: candidate.score)
        }
        return best?.host
    }

    static func stripWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
