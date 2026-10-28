import Foundation

/// DuckDuckGo autoconsent's compact rule set, filtered per frame the way their
/// `filterCompactRules` does: generic rules for every page, site rules only
/// where their URL pattern matches, and the small frame subset in iframes. The
/// 400 KB set is parsed once here, so a page only receives what could apply.
nonisolated final class ConsentRules {
    private let version: Any
    private let strings: [Any]
    private let rules: [[Any]]
    private let genericRange: Range<Int>
    private let frameRange: Range<Int>
    private let specificRange: Range<Int>
    private let genericStringEnd: Int
    private let frameStringEnd: Int
    private var patterns: [String: NSRegularExpression?] = [:]

    init(json: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let strings = root["s"] as? [Any], let rules = root["r"] as? [[Any]],
              let index = root["index"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        func range(_ key: String) throws -> Range<Int> {
            guard let bounds = index[key] as? [Int], bounds.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
            return max(0, bounds[0])..<min(rules.count, bounds[1])
        }
        version = root["v"] ?? 1
        self.strings = strings
        self.rules = rules
        genericRange = try range("genericRuleRange")
        frameRange = try range("frameRuleRange")
        specificRange = try range("specificRuleRange")
        genericStringEnd = min(index["genericStringEnd"] as? Int ?? strings.count, strings.count)
        frameStringEnd = min(index["frameStringEnd"] as? Int ?? strings.count, strings.count)
    }

    /// The `compact` rule bundle for one frame.
    func bundle(for url: String, mainFrame: Bool) -> [String: Any] {
        if !mainFrame {
            return ["v": version, "s": Array(strings[..<frameStringEnd]),
                    "r": rules[frameRange].filter { runs($0, url: url, mainFrame: false) }]
        }
        let generic = Array(rules[genericRange])
        let specific = rules[specificRange].filter { runs($0, url: url, mainFrame: true) }
        if specific.isEmpty {
            return ["v": version, "s": Array(strings[..<genericStringEnd]), "r": generic]
        }
        return ["v": version, "s": strings, "r": generic + specific]
    }

    /// Rule fields: [3] URL pattern (a JavaScript regex), [4] run context.
    private func runs(_ rule: [Any], url: String, mainFrame: Bool) -> Bool {
        let context = rule.count > 4 ? rule[4] as? Int ?? 0 : 0
        if mainFrame && context == 1 { return false }
        if !mainFrame && [20, 22, 10, 12].contains(context) { return false }
        guard rule.count > 3, let pattern = rule[3] as? String, !pattern.isEmpty else { return true }
        guard let regex = regex(pattern) else { return false }
        return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    private func regex(_ pattern: String) -> NSRegularExpression? {
        if let cached = patterns[pattern] { return cached }
        let regex = try? NSRegularExpression(pattern: pattern)
        patterns[pattern] = regex
        return regex
    }
}
