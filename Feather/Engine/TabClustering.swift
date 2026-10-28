import Foundation

/// The math behind automatic tab groups, modelled on Safari's (SafariShared's
/// `WBSPageContext` / `WBSStableCluster`): each tab is described in a short
/// note, the notes are embedded, and HDBSCAN finds the dense groups. Tabs that
/// fit no group stay loose; new tabs join an existing group when they're close
/// to it. Safari uses Apple's private text-embedding service for this, which
/// other apps can't use, so Feather embeds with NaturalLanguage instead.
nonisolated enum TabClustering {
    /// Smallest automatic group. (Safari's default is 3; 2 suits a single window's tabs.)
    static let minimumGroupSize = 2
    /// The k-th nearest tab, counting itself, that sets each tab's core distance.
    static let neighbors = 2
    /// A tab whose average distance to the rest of its group is more than this leaves the group.
    static let outlierDistance = 0.85
    /// A new tab joins an existing group when its average distance to the group is below this.
    static let attachDistance = 0.75

    /// Subtracts the mean vector and normalizes, so the "this is a web page" direction every
    /// note shares doesn't make them all look alike, then returns cosine distances.
    static func distances(_ vectors: [[Double]]) -> [[Double]] {
        guard let width = vectors.first?.count, width > 0 else { return [] }
        let mean = (0..<width).map { d in vectors.reduce(0) { $0 + $1[d] } / Double(vectors.count) }
        let centered = vectors.map { vector -> [Double] in
            let shifted = zip(vector, mean).map { $0 - $1 }
            let norm = sqrt(shifted.reduce(0) { $0 + $1 * $1 })
            return shifted.map { $0 / max(norm, 1e-9) }
        }
        return centered.map { a in centered.map { b in max(0, 1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }) } }
    }

    /// Average distance from `point` to the other `members`.
    static func spread(of point: Int, among members: [Int], _ distances: [[Double]]) -> Double {
        let others = members.filter { $0 != point }
        guard !others.isEmpty else { return 0 }
        return others.reduce(0) { $0 + distances[point][$1] } / Double(others.count)
    }

    /// Groups among `points` (indices into `distances`): HDBSCAN, then members far from the
    /// rest of their group are dropped until every group is tight, and groups too small vanish.
    static func groups(of points: [Int], _ distances: [[Double]]) -> [[Int]] {
        guard points.count >= minimumGroupSize else { return [] }
        let sub = points.map { i in points.map { j in distances[i][j] } }
        let labels = HDBSCAN.labels(distances: sub, minimumClusterSize: minimumGroupSize, neighbors: neighbors,
                                    allowSingleCluster: true)
        var result: [[Int]] = []
        for label in Set(labels).sorted() where label >= 0 {
            var members = points.indices.filter { labels[$0] == label }.map { points[$0] }
            while members.count >= minimumGroupSize,
                  let worst = members.max(by: { spread(of: $0, among: members, distances) < spread(of: $1, among: members, distances) }),
                  spread(of: worst, among: members, distances) > outlierDistance {
                members.removeAll { $0 == worst }
            }
            if members.count >= minimumGroupSize { result.append(members) }
        }
        return result
    }

    /// The existing group (index into `groups`) that `point` should join, if any is close enough.
    static func attach(_ point: Int, to groups: [[Int]], _ distances: [[Double]]) -> Int? {
        let scored = groups.enumerated().compactMap { index, members -> (Int, Double)? in
            members.isEmpty ? nil : (index, spread(of: point, among: members + [point], distances))
        }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 < attachDistance else { return nil }
        return best.0
    }

    /// Without embeddings: tabs whose notes share a topic ("Travel: planning a trip…") form a group.
    static func groupsByTopic(_ notes: [String?]) -> [[Int]] {
        var byTopic: [String: [Int]] = [:]
        var order: [String] = []
        for (index, note) in notes.enumerated() {
            guard let topic = note?.split(separator: ":").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
                  !topic.isEmpty else { continue }
            if byTopic[topic] == nil { order.append(topic) }
            byTopic[topic, default: []].append(index)
        }
        return order.compactMap { byTopic[$0] }.filter { $0.count >= minimumGroupSize }
    }

    /// Site name without the domain ending, like Safari's feature text ("booking" for booking.com).
    static func siteName(_ host: String) -> String {
        Autocomplete.stripWWW(host).replacingOccurrences(of: #"\.[a-zA-Z]{2,6}\b"#, with: "", options: .regularExpression)
    }

    /// One line, no quotes or emoji clutter, at most three whole words and `maxNameLength` characters.
    static let maxNameLength = 24

    static func cleanName(_ name: String) -> String {
        let trimmed = name.components(separatedBy: .newlines).first ?? ""
        let allowed = trimmed.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "&" || $0 == "-" || $0 == "'" }
        let words = allowed.split(separator: " ").map(String.init)
        var result = ""
        for word in words.prefix(3) {
            let longer = result.isEmpty ? word : result + " " + word
            guard longer.count <= maxNameLength else { break }
            result = longer
        }
        return result.isEmpty ? String((words.first ?? "").prefix(maxNameLength)) : result
    }
}
