import Foundation
import CryptoKit
import CoreFoundation
import WebKit
import os

/// One navigation's policy. A permitted parent document also permits its YouTube embeds.
/// Each frame separately checks its own host against the same allowlist snapshot.
nonisolated struct YouTubeBlockingPolicy: Codable, Equatable, Sendable {
    let enabled: Bool
    let allowlistedHosts: [String]
    let topLevelAllowed: Bool

    init(blockContent: Bool, allowlistedHosts: [String], topLevelHost: String?) {
        enabled = blockContent
        self.allowlistedHosts = Array(Set(allowlistedHosts.compactMap(Self.canonicalHost))).sorted()
        topLevelAllowed = !Self.isAllowlisted(topLevelHost, hosts: self.allowlistedHosts)
    }

    func shouldProtect(frameHost: String?) -> Bool {
        enabled && topLevelAllowed && Self.isYouTube(frameHost)
            && !Self.isAllowlisted(frameHost, hosts: allowlistedHosts)
    }

    static func isYouTube(_ host: String?) -> Bool {
        guard let host = canonicalHost(host) else { return false }
        return ["youtube.com", "youtube-nocookie.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isAllowlisted(_ host: String?, hosts: [String]) -> Bool {
        guard let host = canonicalHost(host) else { return false }
        return hosts.compactMap(canonicalHost).contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Used by the settings UI too, so dotted/case aliases can be removed reliably.
    static func updatingAllowlist(_ hosts: [String], host: String, allowed: Bool) -> [String] {
        guard let canonical = canonicalHost(host) else { return hosts }
        var seen: Set<String> = []
        var updated = hosts.compactMap(canonicalHost).filter {
            let remove = allowed ? $0 == canonical : canonical == $0 || canonical.hasSuffix("." + $0)
            return !remove && seen.insert($0).inserted
        }
        if allowed { updated.append(canonical) }
        return updated
    }

    static func canonicalHost(_ value: String?) -> String? {
        guard var host = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
}

/// Untrusted page messages can request only this harmless fixed notice.
nonisolated enum YouTubeAdCatchMessage {
    static let name = "featherYouTubeAdCatch"

    static func isValid(_ body: Any) -> Bool {
        guard let body = body as? [String: Any], body.count == 2,
              body["event"] as? String == "adCaught", let version = body["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1 else { return false }
        return true
    }
}

nonisolated struct YouTubeAdCatchLimiter {
    static let interval: TimeInterval = 30
    static let quarantineInterval: TimeInterval = 5

    struct Ticket: Equatable {
        let id: UUID
        let tabID: UUID
        let mediaKey: String
    }

    enum Rejection: String { case inFlight, cooldown, quarantined, capacity, invalidTime }
    enum Reservation: Equatable { case reserved(Ticket), rejected(Rejection) }
    private struct Key: Hashable { let tabID: UUID; let mediaKey: String }
    private var inFlight: [UUID: Ticket] = [:]
    private var lastNotice: [Key: TimeInterval] = [:]
    private var quarantineUntil: [Key: TimeInterval] = [:]

    mutating func reserve(tabID: UUID, mediaKey: String, uptime: TimeInterval) -> Reservation {
        guard uptime.isFinite, uptime >= 0 else { return .rejected(.invalidTime) }
        lastNotice = lastNotice.filter { uptime - $0.value < Self.interval }
        quarantineUntil = quarantineUntil.filter { $0.value > uptime }
        guard inFlight[tabID] == nil else { return .rejected(.inFlight) }
        let key = Key(tabID: tabID, mediaKey: mediaKey)
        if let until = quarantineUntil[key], uptime < until { return .rejected(.quarantined) }
        if let previous = lastNotice[key], uptime - previous < Self.interval { return .rejected(.cooldown) }
        guard inFlight.count < 128 else { return .rejected(.capacity) }
        let ticket = Ticket(id: UUID(), tabID: tabID, mediaKey: mediaKey)
        inFlight[tabID] = ticket
        return .reserved(ticket)
    }

    /// Record a successful display against the video current after SPA settling.
    @discardableResult
    mutating func commit(_ ticket: Ticket, mediaKey: String, uptime: TimeInterval) -> Bool {
        guard inFlight[ticket.tabID] == ticket, uptime.isFinite, uptime >= 0 else { return false }
        inFlight[ticket.tabID] = nil
        let key = Key(tabID: ticket.tabID, mediaKey: mediaKey)
        quarantineUntil[key] = nil
        if lastNotice.count >= 128, let oldest = lastNotice.min(by: { $0.value < $1.value })?.key {
            lastNotice.removeValue(forKey: oldest)
        }
        lastNotice[key] = uptime
        return true
    }

    @discardableResult
    mutating func release(_ ticket: Ticket, quarantineMediaKey: String? = nil, uptime: TimeInterval) -> Bool {
        guard inFlight[ticket.tabID] == ticket else { return false }
        inFlight[ticket.tabID] = nil
        if let mediaKey = quarantineMediaKey, uptime.isFinite, uptime >= 0 {
            if quarantineUntil.count >= 128, let oldest = quarantineUntil.min(by: { $0.value < $1.value })?.key {
                quarantineUntil[oldest] = nil
            }
            quarantineUntil[Key(tabID: ticket.tabID, mediaKey: mediaKey)] = uptime + Self.quarantineInterval
        }
        return true
    }

    mutating func cancel(tabID: UUID) { inFlight[tabID] = nil }
}

/// An asynchronous notice belongs to one top-level navigation, even on a same-URL reload.
nonisolated struct YouTubeAdNoticeRequest {
    let navigationID: UUID
    let topLevelURL: URL?
    let frameHost: String

    func isCurrent(navigationID: UUID, topLevelURL: URL?, policy: YouTubeBlockingPolicy) -> Bool {
        self.navigationID == navigationID && (self.topLevelURL == topLevelURL || Self.isSameOriginYouTube(self.topLevelURL, topLevelURL))
            && policy.shouldProtect(frameHost: frameHost)
    }

    static func isSameOriginYouTube(_ first: URL?, _ second: URL?) -> Bool {
        guard let first, let second, YouTubeBlockingPolicy.isYouTube(first.host()), YouTubeBlockingPolicy.isYouTube(second.host()),
              let scheme = first.scheme?.lowercased(), ["http", "https"].contains(scheme), second.scheme?.lowercased() == scheme,
              YouTubeBlockingPolicy.canonicalHost(first.host()) == YouTubeBlockingPolicy.canonicalHost(second.host()) else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (first.port ?? defaultPort) == (second.port ?? defaultPort)
    }

    /// Query tracking, timestamps and playlist state do not identify another video.
    static func mediaKey(for url: URL?) -> String {
        guard let url else { return "unknown" }
        guard YouTubeBlockingPolicy.isYouTube(url.host()) else {
            return "embed:" + (YouTubeBlockingPolicy.canonicalHost(url.host()) ?? "unknown")
        }
        let segments = url.path.split(separator: "/").map(String.init)
        let candidate: String?
        if segments.first == "watch" {
            candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
        } else if let first = segments.first, ["shorts", "embed", "live", "v"].contains(first), segments.count >= 2 {
            candidate = segments[1]
        } else { candidate = nil }
        if let candidate, candidate.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            return "video:" + candidate
        }
        return "youtube:" + String((segments.first ?? "home").prefix(64))
    }
}

nonisolated enum YouTubeAdNoticeResult: Equatable {
    case shown, notShown, indeterminate
    var shouldUseNativeFallback: Bool { self == .notShown }
}

/// Only an explicit non-presentation permits a second presentation channel.
nonisolated enum YouTubeAdNoticeOutcome: String {
    case shown, declined, unavailable, startExpired, timedOut, evaluationFailed, invalidResult

    var result: YouTubeAdNoticeResult {
        switch self {
        case .shown: .shown
        case .declined, .unavailable, .startExpired: .notShown
        case .timedOut, .evaluationFailed, .invalidResult: .indeterminate
        }
    }
}

/// An on-time mount may have a delayed acknowledgement. A timeout wins once;
/// a late callback cannot change it into a second display or increment a count.
nonisolated struct YouTubeAdNoticeCompletion {
    private(set) var outcome: YouTubeAdNoticeOutcome?

    mutating func accept(_ value: YouTubeAdNoticeOutcome) -> Bool {
        guard outcome == nil else { return false }
        outcome = value
        return true
    }
}

/// Pending callbacks must not survive disabling and re-enabling feedback.
nonisolated struct YouTubeAdNoticePreference {
    private(set) var enabled = false
    private(set) var revision = 0

    @discardableResult
    mutating func update(enabled: Bool) -> Bool {
        guard self.enabled != enabled else { return false }
        self.enabled = enabled
        revision += 1
        return true
    }

    mutating func invalidate() {
        enabled = false
        revision += 1
    }

    func permits(revision: Int) -> Bool { enabled && self.revision == revision }
}

/// Pure composition is shared by production and tests; vendor source is inserted unchanged.
nonisolated enum YouTubeScriptComposition {
    static let scriptMarker = "// Feather YouTube protection — managed user script"
    static let stampScriptMarker = "// Feather YouTube isolated policy stamp — managed user script"
    static let noticeScriptMarker = "// Feather YouTube isolated ad notice — managed user script"
    static let upstreamMarker = "/*__FEATHER_UPSTREAM__*/"

    enum Failure: LocalizedError {
        case emptySource(String)
        case invalidUpstreamMarker

        var errorDescription: String? {
            switch self {
            case .emptySource(let name): "YouTube protection source \(name) is empty."
            case .invalidUpstreamMarker: "YouTube protection template must contain exactly one upstream marker."
            }
        }
    }

    static func source(template: String, upstream: String, policy: YouTubeBlockingPolicy) throws -> String {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptySource("template") }
        guard !upstream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptySource("upstream") }
        guard template.components(separatedBy: upstreamMarker).count == 2 else { throw Failure.invalidUpstreamMarker }
        let json = String(decoding: try encodedPolicy(policy), as: UTF8.self)
        let body = template.replacingOccurrences(of: upstreamMarker, with: upstream)
        return """
            \(scriptMarker)
            (() => {
            const __FEATHER_POLICY__ = \(json);
            \(body)
            })();
            """
    }

    /// Used only in Feather's isolated world, including when blocking is off.
    static func policyStamp(_ policy: YouTubeBlockingPolicy) throws -> String {
        SHA256.hash(data: try encodedPolicy(policy)).map { String(format: "%02x", $0) }.joined()
    }

    static func isolatedStampSource(policy: YouTubeBlockingPolicy) throws -> String {
        "\(stampScriptMarker)\nObject.defineProperty(globalThis, '__featherYouTubePolicyStamp', { value: '\(try policyStamp(policy))', writable: false, configurable: false });"
    }

    static func isolatedNoticeSource(_ source: String) throws -> String {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptySource("notice") }
        return "\(noticeScriptMarker)\n\(source)"
    }

    private static func encodedPolicy(_ policy: YouTubeBlockingPolicy) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(policy)
    }
}

/// Composes protection scripts; the separate factory handler accepts only fixed UI feedback.
enum YouTubeAdBlocker {
    private struct Sources {
        let template: String
        let upstream: String
    }

    /// WKUserScript is immutable. Share the prepared objects between tabs instead
    /// of rebuilding the large vendor source on every navigation. Keep settings
    /// changes bounded rather than retaining every allowlist ever used.
    private static let scriptCacheLimit = 8
    private static var scriptBundles: [(policy: YouTubeBlockingPolicy, scripts: [WKUserScript])] = []

    private final class AppliedScripts {
        let policy: YouTubeBlockingPolicy
        let scripts: [WKUserScript]

        init(policy: YouTubeBlockingPolicy, scripts: [WKUserScript]) {
            self.policy = policy
            // WebKit's getter can bridge its mutable NSArray. Materialize a
            // native Swift buffer so later controller mutations cannot also
            // mutate the snapshot used to detect those changes.
            self.scripts = scripts.map { $0 }
        }

        func matches(_ scripts: [WKUserScript], policy: YouTubeBlockingPolicy) -> Bool {
            self.policy == policy && self.scripts.count == scripts.count
                && zip(self.scripts, scripts).allSatisfy { $0 === $1 }
        }
    }

    /// The snapshot includes unrelated scripts too: an external remove/replace
    /// invalidates the fast path, so refresh still repairs the controller.
    private static let appliedScripts = NSMapTable<WKUserContentController, AppliedScripts>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)

    private static let log = Logger(subsystem: "dev.nesbes.Feather", category: "YouTubeBlocking")
    private static let sources: Sources? = {
        do {
            func read(_ name: String, subdirectory: String) throws -> String {
                guard let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: subdirectory) else {
                    throw NSError(domain: "Feather.YouTubeBlocking", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing bundled \(subdirectory)/\(name).js"])
                }
                return try String(contentsOf: url, encoding: .utf8)
            }
            return try Sources(template: read("protection", subdirectory: "YouTube"),
                               upstream: read("youtube-upstream", subdirectory: "YouTube/upstream"))
        } catch {
            log.error("YouTube protection unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    private static let noticeSource: String? = {
        do {
            guard let url = Bundle.main.url(forResource: "notice", withExtension: "js", subdirectory: "YouTube") else {
                throw NSError(domain: "Feather.YouTubeBlocking", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Missing bundled YouTube/notice.js"])
            }
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            log.error("YouTube in-page notice unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static func script(policy: YouTubeBlockingPolicy) -> WKUserScript? {
        guard let sources else { return nil }
        do {
            return WKUserScript(source: try YouTubeScriptComposition.source(template: sources.template, upstream: sources.upstream, policy: policy),
                                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        } catch {
            log.error("YouTube protection unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func stampScript(policy: YouTubeBlockingPolicy) -> WKUserScript? {
        do {
            return WKUserScript(source: try YouTubeScriptComposition.isolatedStampSource(policy: policy),
                                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)
        } catch {
            log.error("YouTube policy stamp unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func noticeScript(source: String) throws -> WKUserScript {
        WKUserScript(source: try YouTubeScriptComposition.isolatedNoticeSource(source),
                     injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
    }

    private static let preparedNoticeScript: WKUserScript? = {
        guard let noticeSource else { return nil }
        do { return try noticeScript(source: noticeSource) }
        catch {
            log.error("YouTube in-page notice unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static func noticeScript() -> WKUserScript? { preparedNoticeScript }

    private static func preparedScripts(policy: YouTubeBlockingPolicy) -> [WKUserScript] {
        if let index = scriptBundles.firstIndex(where: { $0.policy == policy }) {
            let bundle = scriptBundles.remove(at: index)
            scriptBundles.append(bundle)
            return bundle.scripts
        }
        // Prepare isolated UI before page-world protection can report a catch.
        let scripts = [noticeScript(), script(policy: policy), stampScript(policy: policy)].compactMap { $0 }
        scriptBundles.append((policy, scripts))
        if scriptBundles.count > scriptCacheLimit { scriptBundles.removeFirst() }
        return scripts
    }

    /// Refresh before allowing a main navigation. WebKit has no remove-one-user-script API,
    /// so preserve every unrelated script object and its position while replacing ours.
    static func refresh(in controller: WKUserContentController, policy: YouTubeBlockingPolicy) {
        let existing = controller.userScripts
        if appliedScripts.object(forKey: controller)?.matches(existing, policy: policy) == true { return }
        let replacements = preparedScripts(policy: policy)
        let managed = existing.filter { isManaged($0) }
        if managed.count == replacements.count,
           replacements.allSatisfy({ replacement in managed.contains { $0.source == replacement.source } }) {
            appliedScripts.setObject(AppliedScripts(policy: policy, scripts: existing), forKey: controller)
            return
        }
        let updated = replacingProtection(in: existing, with: replacements)
        controller.removeAllUserScripts()
        updated.forEach(controller.addUserScript)
        appliedScripts.setObject(AppliedScripts(policy: policy, scripts: controller.userScripts), forKey: controller)
    }

    static func replacingProtection(in existing: [WKUserScript], with replacements: [WKUserScript]) -> [WKUserScript] {
        var updated: [WKUserScript] = []
        var inserted: Set<String> = []
        for script in existing {
            if let marker = managedMarker(script) {
                if !inserted.contains(marker), let replacement = replacements.first(where: { managedMarker($0) == marker }) {
                    updated.append(replacement)
                }
                inserted.insert(marker)
            } else { updated.append(script) }
        }
        for replacement in replacements {
            if let marker = managedMarker(replacement), !inserted.contains(marker) {
                updated.append(replacement)
                inserted.insert(marker)
            }
        }
        return updated
    }

    private static func isManaged(_ script: WKUserScript) -> Bool {
        managedMarker(script) != nil
    }

    private static func managedMarker(_ script: WKUserScript) -> String? {
        [YouTubeScriptComposition.scriptMarker, YouTubeScriptComposition.stampScriptMarker,
         YouTubeScriptComposition.noticeScriptMarker].first { script.source.hasPrefix($0) }
    }
}
