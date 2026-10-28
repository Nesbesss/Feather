import XCTest
import WebKit

final class YouTubeBlockingPolicyTests: XCTestCase {
    func testOnlyYouTubeAndPrivacyEmbedHostsAreProtected() {
        let policy = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: [], topLevelHost: "example.org")
        for host in ["youtube.com", "www.youtube.com", "m.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com", "WWW.YOUTUBE.COM."] {
            XCTAssertTrue(policy.shouldProtect(frameHost: host), host)
        }
        for host in [nil, "notyoutube.com", "youtube.com.evil.example", "youtube-nocookie.com.example", "youtu.be", "example.org"] {
            XCTAssertFalse(policy.shouldProtect(frameHost: host), host ?? "nil")
        }
    }

    func testGlobalSwitchDisablesMainFramesAndEmbeds() {
        let policy = YouTubeBlockingPolicy(blockContent: false, allowlistedHosts: [], topLevelHost: "example.org")
        XCTAssertFalse(policy.shouldProtect(frameHost: "youtube.com"))
        XCTAssertFalse(policy.shouldProtect(frameHost: "www.youtube-nocookie.com"))
    }

    func testAllowlistedParentDisablesAllYouTubeEmbeds() {
        let policy = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: ["example.org"], topLevelHost: "news.example.org")
        XCTAssertFalse(policy.topLevelAllowed)
        XCTAssertFalse(policy.shouldProtect(frameHost: "youtube.com"))
        XCTAssertFalse(policy.shouldProtect(frameHost: "youtube-nocookie.com"))
    }

    func testFrameAllowlistIsAppliedWithDomainBoundaries() {
        let policy = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: ["www.youtube.com"], topLevelHost: "example.org")
        XCTAssertTrue(policy.topLevelAllowed)
        XCTAssertFalse(policy.shouldProtect(frameHost: "www.youtube.com"))
        XCTAssertFalse(policy.shouldProtect(frameHost: "child.www.youtube.com"))
        XCTAssertTrue(policy.shouldProtect(frameHost: "youtube.com"))
        XCTAssertTrue(policy.shouldProtect(frameHost: "www.youtube-nocookie.com"))
        XCTAssertFalse(YouTubeBlockingPolicy.isAllowlisted("badexample.org", hosts: ["example.org"]))
        XCTAssertFalse(YouTubeBlockingPolicy.isAllowlisted("example.org.evil", hosts: ["example.org"]))
    }

    func testReloadPolicyReflectsChangedSettingsRatherThanCreationSnapshot() {
        let first = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: [], topLevelHost: "www.youtube.com")
        let reload = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: ["YouTube.com."], topLevelHost: "www.youtube.com")
        XCTAssertTrue(first.shouldProtect(frameHost: "www.youtube.com"))
        XCTAssertFalse(reload.shouldProtect(frameHost: "www.youtube.com"))
        XCTAssertFalse(reload.topLevelAllowed)
        XCTAssertEqual(reload.allowlistedHosts, ["youtube.com"])
    }

    func testCompositionUsesVerbatimUpstreamAndBoundedPolicyConfiguration() throws {
        let policy = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: ["youtube.com"], topLevelHost: "example.org")
        let upstream = "/* vendor license */\nconst vendorValue = '$&';\n"
        let template = "if (__FEATHER_POLICY__.enabled) {\n/*__FEATHER_UPSTREAM__*/\n}"
        let source = try YouTubeScriptComposition.source(template: template, upstream: upstream, policy: policy)
        XCTAssertTrue(source.hasPrefix(YouTubeScriptComposition.scriptMarker))
        XCTAssertTrue(source.contains(upstream))
        XCTAssertFalse(source.contains(YouTubeScriptComposition.upstreamMarker))
        XCTAssertTrue(source.contains("\"enabled\":true"))
        XCTAssertTrue(source.contains("\"topLevelAllowed\":true"))
        XCTAssertTrue(source.contains("\"allowlistedHosts\":[\"youtube.com\"]"))
        XCTAssertThrowsError(try YouTubeScriptComposition.source(template: "missing", upstream: upstream, policy: policy))
        XCTAssertThrowsError(try YouTubeScriptComposition.source(template: template + template, upstream: upstream, policy: policy))
        XCTAssertThrowsError(try YouTubeScriptComposition.source(template: template, upstream: " ", policy: policy))
    }

    func testReplacingProtectionPreservesEveryUnrelatedScriptAndOrder() {
        func script(_ source: String) -> WKUserScript { WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page) }
        let before = script("passwords"), old = script(YouTubeScriptComposition.scriptMarker + "\nold"), after = script("consent")
        let replacement = script(YouTubeScriptComposition.scriptMarker + "\nnew")
        let updated = YouTubeAdBlocker.replacingProtection(in: [before, old, after], with: [replacement])
        XCTAssertEqual(updated.count, 3)
        XCTAssertTrue(updated[0] === before)
        XCTAssertTrue(updated[1] === replacement)
        XCTAssertTrue(updated[2] === after)
        let disabled = YouTubeAdBlocker.replacingProtection(in: updated, with: [])
        XCTAssertEqual(disabled.count, 2)
        XCTAssertTrue(disabled[0] === before)
        XCTAssertTrue(disabled[1] === after)
    }

    func testRefreshRepairsExternallyRemovedScriptsWithoutLosingOtherScripts() throws {
        let policy = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: [], topLevelHost: "example.org")
        let controller = WKUserContentController()
        YouTubeAdBlocker.refresh(in: controller, policy: policy)
        let expected = controller.userScripts.map(\.source)
        XCTAssertFalse(expected.isEmpty)
        controller.removeAllUserScripts()
        let unrelated = WKUserScript(source: "window.unrelated = true", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        controller.addUserScript(unrelated)
        YouTubeAdBlocker.refresh(in: controller, policy: policy)
        XCTAssertTrue(controller.userScripts.first === unrelated)
        XCTAssertEqual(Array(controller.userScripts.dropFirst()).map(\.source), expected)
    }

    func testRefreshRepairsReplacedManagedScriptAndPreservesNewUnrelatedScript() {
        let policy = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: [], topLevelHost: "example.org")
        let controller = WKUserContentController()
        YouTubeAdBlocker.refresh(in: controller, policy: policy)
        let expected = controller.userScripts.map(\.source)
        let unrelated = WKUserScript(source: "window.addedLater = true", injectionTime: .atDocumentStart, forMainFrameOnly: false)
        controller.addUserScript(unrelated)
        YouTubeAdBlocker.refresh(in: controller, policy: policy)
        XCTAssertTrue(controller.userScripts.last === unrelated)
        XCTAssertEqual(Array(controller.userScripts.dropLast()).map(\.source), expected)
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: YouTubeScriptComposition.stampScriptMarker + " stale policy",
                                            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(unrelated)
        YouTubeAdBlocker.refresh(in: controller, policy: policy)
        XCTAssertTrue(controller.userScripts.contains { $0 === unrelated })
        XCTAssertFalse(controller.userScripts.contains { $0.source.contains("stale policy") })
        XCTAssertTrue(expected.allSatisfy { source in controller.userScripts.contains { $0.source == source } })
    }

    func testCachedRefreshTracksAllowlistChangesAndCanonicalEquivalentPolicies() throws {
        let controller = WKUserContentController()
        let normal = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: ["EXAMPLE.ORG."], topLevelHost: "youtube.com")
        let equivalent = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: ["example.org", "example.org"], topLevelHost: "youtube.com")
        let off = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: ["youtube.com"], topLevelHost: "youtube.com")
        YouTubeAdBlocker.refresh(in: controller, policy: normal)
        let first = controller.userScripts
        YouTubeAdBlocker.refresh(in: controller, policy: equivalent)
        XCTAssertEqual(controller.userScripts.count, first.count)
        XCTAssertTrue(zip(controller.userScripts, first).allSatisfy { $0 === $1 })
        YouTubeAdBlocker.refresh(in: controller, policy: off)
        let stamp = try YouTubeScriptComposition.policyStamp(off)
        let previousStamp = try YouTubeScriptComposition.policyStamp(normal)
        XCTAssertTrue(controller.userScripts.contains { $0.source.hasPrefix(YouTubeScriptComposition.stampScriptMarker) && $0.source.contains(stamp) })
        XCTAssertFalse(controller.userScripts.contains { $0.source.contains(previousStamp) })
    }

    func testScriptCacheDoesNotKeepControllersAlive() {
        weak var weakController: WKUserContentController?
        autoreleasepool {
            let controller = WKUserContentController()
            weakController = controller
            YouTubeAdBlocker.refresh(in: controller, policy: YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: [], topLevelHost: "example.org"))
        }
        XCTAssertNil(weakController)
    }

    func testCacheStampChangesWithPolicyAndStaysOutOfPageWorld() throws {
        let normal = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: ["youtube.com", "example.org"], topLevelHost: "other.example")
        let canonical = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: ["EXAMPLE.ORG.", "youtube.com", "youtube.com"], topLevelHost: "other.example")
        let off = YouTubeBlockingPolicy(blockContent: false, allowlistedHosts: normal.allowlistedHosts, topLevelHost: "other.example")
        let permittedParent = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: normal.allowlistedHosts, topLevelHost: "example.org")
        let differentAllowlist = YouTubeBlockingPolicy(blockContent: true, allowlistedHosts: [], topLevelHost: "other.example")
        let stamp = try YouTubeScriptComposition.policyStamp(normal)
        XCTAssertEqual(stamp, try YouTubeScriptComposition.policyStamp(canonical))
        XCTAssertNotEqual(stamp, try YouTubeScriptComposition.policyStamp(off))
        XCTAssertNotEqual(stamp, try YouTubeScriptComposition.policyStamp(permittedParent))
        XCTAssertNotEqual(stamp, try YouTubeScriptComposition.policyStamp(differentAllowlist))
        XCTAssertNotNil(stamp.range(of: "^[a-f0-9]{64}$", options: .regularExpression))
        XCTAssertFalse(stamp.contains("youtube.com"))
        XCTAssertFalse(stamp.contains("example.org"))
        let template = "if (!__FEATHER_POLICY__.enabled) return;\n/*__FEATHER_UPSTREAM__*/"
        let source = try YouTubeScriptComposition.source(template: template, upstream: "/* upstream */", policy: off)
        XCTAssertFalse(source.contains("__featherYouTubePolicyStamp"))
        XCTAssertFalse(source.contains(try YouTubeScriptComposition.policyStamp(off)))
        let isolated = try YouTubeScriptComposition.isolatedStampSource(policy: off)
        XCTAssertTrue(isolated.contains("__featherYouTubePolicyStamp"))
        XCTAssertFalse(isolated.contains("youtube.com"))
        XCTAssertFalse(isolated.contains("example.org"))
        let stampScript = try XCTUnwrap(YouTubeAdBlocker.stampScript(policy: off))
        XCTAssertEqual(stampScript.injectionTime, .atDocumentStart)
        XCTAssertFalse(stampScript.isForMainFrameOnly)
    }

    func testPageAndIsolatedScriptsKeepTheirSeparatePositions() {
        func script(_ source: String) -> WKUserScript { WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false) }
        let first = script("passwords"), middle = script("consent"), last = script("media")
        let oldPage = script(YouTubeScriptComposition.scriptMarker + " old")
        let oldStamp = script(YouTubeScriptComposition.stampScriptMarker + " old")
        let newPage = script(YouTubeScriptComposition.scriptMarker + " new")
        let newStamp = script(YouTubeScriptComposition.stampScriptMarker + " new")
        let updated = YouTubeAdBlocker.replacingProtection(in: [first, oldPage, middle, oldStamp, last], with: [newPage, newStamp])
        XCTAssertEqual(updated.count, 5)
        XCTAssertTrue(updated[0] === first)
        XCTAssertTrue(updated[1] === newPage)
        XCTAssertTrue(updated[2] === middle)
        XCTAssertTrue(updated[3] === newStamp)
        XCTAssertTrue(updated[4] === last)
    }

    func testNoticeIsAMainFrameDocumentStartScriptWithoutPolicyData() throws {
        let body = "Object.defineProperty(globalThis, '__featherYouTubeAdNotice', {value: Object.freeze({show: async () => true})});"
        let script = try YouTubeAdBlocker.noticeScript(source: body)
        XCTAssertEqual(script.injectionTime, .atDocumentStart)
        XCTAssertTrue(script.isForMainFrameOnly)
        XCTAssertTrue(script.source.hasPrefix(YouTubeScriptComposition.noticeScriptMarker))
        XCTAssertTrue(script.source.contains(body))
        XCTAssertFalse(script.source.contains("__FEATHER_POLICY__"))
        XCTAssertFalse(script.source.contains("__featherYouTubePolicyStamp"))
        XCTAssertThrowsError(try YouTubeAdBlocker.noticeScript(source: " \n"))
    }

    func testThirdManagedScriptPreservesExistingScriptsAndMigratesControllers() {
        func script(_ source: String) -> WKUserScript { WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false) }
        let first = script("passwords"), last = script("consent")
        let oldPage = script(YouTubeScriptComposition.scriptMarker + " old")
        let oldStamp = script(YouTubeScriptComposition.stampScriptMarker + " old")
        let oldNotice = script(YouTubeScriptComposition.noticeScriptMarker + " old")
        let newPage = script(YouTubeScriptComposition.scriptMarker + " new")
        let newStamp = script(YouTubeScriptComposition.stampScriptMarker + " new")
        let newNotice = script(YouTubeScriptComposition.noticeScriptMarker + " new")
        let replacements = [newPage, newStamp, newNotice]
        let migrated = YouTubeAdBlocker.replacingProtection(in: [first, oldPage, oldStamp, last], with: replacements)
        XCTAssertEqual(migrated.count, 5)
        XCTAssertTrue(migrated[0] === first)
        XCTAssertTrue(migrated[1] === newPage)
        XCTAssertTrue(migrated[2] === newStamp)
        XCTAssertTrue(migrated[3] === last)
        XCTAssertTrue(migrated[4] === newNotice)
        let updated = YouTubeAdBlocker.replacingProtection(in: [first, oldNotice, oldPage, last, oldStamp], with: replacements)
        XCTAssertTrue(updated[0] === first)
        XCTAssertTrue(updated[1] === newNotice)
        XCTAssertTrue(updated[2] === newPage)
        XCTAssertTrue(updated[3] === last)
        XCTAssertTrue(updated[4] === newStamp)
        XCTAssertEqual(YouTubeAdBlocker.replacingProtection(in: updated, with: []).count, 2)
    }

    func testNoticeCompletionAllowsYouTubeSPAWithinSameDocumentAndCurrentPolicy() {
        let navigationID = UUID()
        let url = URL(string: "https://www.youtube.com/watch?v=one")!
        let request = YouTubeAdNoticeRequest(navigationID: navigationID, topLevelURL: url, frameHost: "www.youtube.com")
        func policy(_ enabled: Bool = true, _ hosts: [String] = []) -> YouTubeBlockingPolicy {
            YouTubeBlockingPolicy(blockContent: enabled, allowlistedHosts: hosts, topLevelHost: "www.youtube.com")
        }
        XCTAssertTrue(request.isCurrent(navigationID: navigationID, topLevelURL: url, policy: policy()))
        // A same-URL reload is a different document and cannot show a stale fallback.
        XCTAssertFalse(request.isCurrent(navigationID: UUID(), topLevelURL: url, policy: policy()))
        XCTAssertTrue(request.isCurrent(navigationID: navigationID, topLevelURL: URL(string: "https://www.youtube.com/watch?v=two"), policy: policy()))
        XCTAssertTrue(request.isCurrent(navigationID: navigationID, topLevelURL: URL(string: "https://www.youtube.com/watch?v=one&t=20#details"), policy: policy()))
        for foreign in ["https://example.org/", "https://m.youtube.com/watch?v=two", "https://www.youtube-nocookie.com/embed/two", "http://www.youtube.com/watch?v=two", "https://www.youtube.com:444/watch?v=two"] {
            XCTAssertFalse(request.isCurrent(navigationID: navigationID, topLevelURL: URL(string: foreign), policy: policy()), foreign)
        }
        XCTAssertFalse(request.isCurrent(navigationID: navigationID, topLevelURL: nil, policy: policy()))
        XCTAssertFalse(request.isCurrent(navigationID: navigationID, topLevelURL: url, policy: policy(false)))
        XCTAssertFalse(request.isCurrent(navigationID: navigationID, topLevelURL: url, policy: policy(true, ["youtube.com"])))
    }

    func testOnlyConfirmedNonPresentationPermitsNativeFallback() {
        for outcome: YouTubeAdNoticeOutcome in [.timedOut, .evaluationFailed, .invalidResult] {
            XCTAssertEqual(outcome.result, .indeterminate)
            XCTAssertFalse(outcome.result.shouldUseNativeFallback)
        }
        for outcome: YouTubeAdNoticeOutcome in [.declined, .unavailable, .startExpired] {
            XCTAssertEqual(outcome.result, .notShown)
            XCTAssertTrue(outcome.result.shouldUseNativeFallback)
        }
        XCTAssertEqual(YouTubeAdNoticeOutcome.shown.result, .shown)
        XCTAssertFalse(YouTubeAdNoticeOutcome.shown.result.shouldUseNativeFallback)
    }

    func testMountedNoticeWithDelayedAcknowledgementCannotProduceFallback() {
        var completion = YouTubeAdNoticeCompletion()
        // The DOM may already be mounted while the WebContent acknowledgement
        // is delayed. The native deadline establishes no absence of UI.
        XCTAssertTrue(completion.accept(.timedOut))
        XCTAssertEqual(completion.outcome, .timedOut)
        XCTAssertFalse(completion.outcome!.result.shouldUseNativeFallback)
        // A late successful (or failed) callback cannot resume the continuation
        // again, change counters, or open a second presentation channel.
        XCTAssertFalse(completion.accept(.shown))
        XCTAssertFalse(completion.accept(.evaluationFailed))
        XCTAssertEqual(completion.outcome, .timedOut)
        var explicitAbsence = YouTubeAdNoticeCompletion()
        XCTAssertTrue(explicitAbsence.accept(.unavailable))
        XCTAssertTrue(explicitAbsence.outcome!.result.shouldUseNativeFallback)
        XCTAssertFalse(explicitAbsence.accept(.timedOut))
    }

    func testNoticePreferenceDefaultsOffAndCancelsAcrossRapidOffOnCycle() {
        var preference = YouTubeAdNoticePreference()
        XCTAssertFalse(preference.enabled)
        XCTAssertFalse(preference.permits(revision: 0))
        XCTAssertTrue(preference.update(enabled: true))
        let pendingRevision = preference.revision
        XCTAssertTrue(preference.permits(revision: pendingRevision))
        // Observation invalidates synchronously before reading the changed value.
        preference.invalidate()
        XCTAssertFalse(preference.enabled)
        XCTAssertFalse(preference.permits(revision: pendingRevision))
        // Even if off/on writes coalesce, the old pending catch cannot resume.
        XCTAssertTrue(preference.update(enabled: true))
        XCTAssertTrue(preference.permits(revision: preference.revision))
        XCTAssertFalse(preference.permits(revision: pendingRevision))
        let currentRevision = preference.revision
        XCTAssertFalse(preference.update(enabled: true))
        XCTAssertEqual(preference.revision, currentRevision)
        XCTAssertTrue(preference.update(enabled: false))
        XCTAssertFalse(preference.permits(revision: currentRevision))
    }

    func testSettingsAllowlistUpdatesRemoveCanonicalAliases() {
        let original = [" YouTube.COM. ", "youtube.com", "EXAMPLE.ORG.", "example.org"]
        XCTAssertTrue(YouTubeBlockingPolicy.isAllowlisted("www.youtube.com", hosts: original))
        let removed = YouTubeBlockingPolicy.updatingAllowlist(original, host: "youtube.com...", allowed: false)
        XCTAssertEqual(removed, ["example.org"])
        XCTAssertFalse(YouTubeBlockingPolicy.isAllowlisted("www.youtube.com", hosts: removed))
        let added = YouTubeBlockingPolicy.updatingAllowlist(removed, host: " WWW.YouTube.com. \n", allowed: true)
        XCTAssertEqual(added, ["example.org", "www.youtube.com"])
        XCTAssertTrue(YouTubeBlockingPolicy.isAllowlisted("www.youtube.com.", hosts: added))
        XCTAssertEqual(YouTubeBlockingPolicy.updatingAllowlist(added, host: " . ", allowed: false), added)
        let inherited = YouTubeBlockingPolicy.updatingAllowlist(["youtube.com", "news.youtube.com", "other.example"], host: "www.youtube.com", allowed: false)
        XCTAssertEqual(inherited, ["news.youtube.com", "other.example"])
        XCTAssertFalse(YouTubeBlockingPolicy.isAllowlisted("www.youtube.com", hosts: inherited))
        XCTAssertTrue(YouTubeBlockingPolicy.isAllowlisted("news.youtube.com", hosts: inherited))
    }

    func testBlockingBooleanReadsLaunchStringsAndStoredValues() throws {
        let name = "FeatherYouTubePreferenceTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let key = "FeatherBlockContent"
        XCTAssertTrue(PreferenceValue.bool(forKey: key, in: defaults, default: true))
        // These are the same NSString values supplied by NSArgumentDomain;
        // keep the fixture in a unique suite rather than changing runner arguments.
        defaults.set("NO", forKey: key)
        XCTAssertNil(defaults.object(forKey: key) as? Bool)
        XCTAssertFalse(PreferenceValue.bool(forKey: key, in: defaults, default: true))
        defaults.set("YES", forKey: key)
        XCTAssertTrue(PreferenceValue.bool(forKey: key, in: defaults, default: false))
        defaults.set(false, forKey: key)
        XCTAssertFalse(PreferenceValue.bool(forKey: key, in: defaults, default: true))
        defaults.set(true, forKey: key)
        XCTAssertTrue(PreferenceValue.bool(forKey: key, in: defaults, default: false))
    }

    func testCatchMessageAcceptsOnlyFixedSchema() {
        XCTAssertTrue(YouTubeAdCatchMessage.isValid(["version": 1, "event": "adCaught"]))
        for body: Any in [
            ["version": true, "event": "adCaught"], ["version": 2, "event": "adCaught"],
            ["version": "1", "event": "adCaught"], ["version": 1.5, "event": "adCaught"],
            ["version": 1, "event": "installed"], ["version": 1, "event": "adCaught", "message": "arbitrary"],
            "adCaught", ["event": "adCaught"],
        ] { XCTAssertFalse(YouTubeAdCatchMessage.isValid(body)) }
    }

    func testCancelledCatchDoesNotSpendPresentationCooldown() {
        var limiter = YouTubeAdCatchLimiter()
        let tab = UUID()
        guard case .reserved(let first) = limiter.reserve(tabID: tab, mediaKey: "video:one", uptime: 100) else { return XCTFail("First event must reserve") }
        XCTAssertEqual(limiter.reserve(tabID: tab, mediaKey: "video:two", uptime: 100.1), .rejected(.inFlight))
        XCTAssertTrue(limiter.release(first, uptime: 101))
        guard case .reserved(let retry) = limiter.reserve(tabID: tab, mediaKey: "video:one", uptime: 101.1) else { return XCTFail("Failed presentation must remain eligible") }
        XCTAssertTrue(limiter.release(retry, uptime: 101.2))
        XCTAssertEqual(limiter.reserve(tabID: tab, mediaKey: "video:one", uptime: .infinity), .rejected(.invalidTime))
        XCTAssertEqual(limiter.reserve(tabID: tab, mediaKey: "video:one", uptime: -1), .rejected(.invalidTime))
    }

    func testPresentationCooldownStartsAtConfirmationAndIsPerVideo() {
        var limiter = YouTubeAdCatchLimiter()
        let tab = UUID(), otherTab = UUID()
        guard case .reserved(let first) = limiter.reserve(tabID: tab, mediaKey: "video:one", uptime: 100) else { return XCTFail() }
        XCTAssertTrue(limiter.commit(first, mediaKey: "video:one", uptime: 106))
        guard case .reserved(let secondVideo) = limiter.reserve(tabID: tab, mediaKey: "video:two", uptime: 107) else { return XCTFail("Another video must not inherit this video's cooldown") }
        XCTAssertTrue(limiter.commit(secondVideo, mediaKey: "video:two", uptime: 107.1))
        guard case .reserved(let separateTab) = limiter.reserve(tabID: otherTab, mediaKey: "video:one", uptime: 108) else { return XCTFail() }
        XCTAssertTrue(limiter.release(separateTab, uptime: 108.1))
        XCTAssertEqual(limiter.reserve(tabID: tab, mediaKey: "video:one", uptime: 135.9), .rejected(.cooldown))
        guard case .reserved(let afterCooldown) = limiter.reserve(tabID: tab, mediaKey: "video:one", uptime: 136) else { return XCTFail("Cooldown starts on confirmed presentation") }
        XCTAssertTrue(limiter.release(afterCooldown, uptime: 136.1))
    }

    func testIndeterminatePresentationUsesShortPerVideoQuarantine() {
        var limiter = YouTubeAdCatchLimiter()
        let tab = UUID()
        guard case .reserved(let first) = limiter.reserve(tabID: tab, mediaKey: "video:one", uptime: 100) else { return XCTFail() }
        XCTAssertTrue(limiter.release(first, quarantineMediaKey: "video:one", uptime: 101))
        guard case .reserved(let otherVideo) = limiter.reserve(tabID: tab, mediaKey: "video:two", uptime: 102) else { return XCTFail() }
        XCTAssertTrue(limiter.release(otherVideo, uptime: 102.1))
        XCTAssertEqual(limiter.reserve(tabID: tab, mediaKey: "video:one", uptime: 105.9), .rejected(.quarantined))
        guard case .reserved(let retry) = limiter.reserve(tabID: tab, mediaKey: "video:one", uptime: 106) else { return XCTFail("Timeout must not spend the 30 second success cooldown") }
        XCTAssertTrue(limiter.release(retry, uptime: 106.1))
    }

    func testSPACarriedCatchCommitsAgainstPresentedVideo() {
        var limiter = YouTubeAdCatchLimiter()
        let tab = UUID()
        guard case .reserved(let pending) = limiter.reserve(tabID: tab, mediaKey: "video:beforeTransition", uptime: 100) else { return XCTFail() }
        XCTAssertTrue(limiter.commit(pending, mediaKey: "video:afterTransition", uptime: 103))
        XCTAssertEqual(limiter.reserve(tabID: tab, mediaKey: "video:afterTransition", uptime: 103.1), .rejected(.cooldown))
        guard case .reserved(let originalVideo) = limiter.reserve(tabID: tab, mediaKey: "video:beforeTransition", uptime: 104) else { return XCTFail("The pre-transition URL did not receive a presentation") }
        XCTAssertTrue(limiter.release(originalVideo, uptime: 104.1))
    }

    func testOldDocumentCompletionCannotReleaseNewDocumentTicket() {
        var limiter = YouTubeAdCatchLimiter()
        let tab = UUID()
        guard case .reserved(let old) = limiter.reserve(tabID: tab, mediaKey: "video:one", uptime: 100) else { return XCTFail() }
        limiter.cancel(tabID: tab)
        guard case .reserved(let current) = limiter.reserve(tabID: tab, mediaKey: "video:two", uptime: 100.1) else { return XCTFail() }
        XCTAssertFalse(limiter.release(old, quarantineMediaKey: "video:two", uptime: 100.2))
        XCTAssertFalse(limiter.commit(old, mediaKey: "video:two", uptime: 100.3))
        XCTAssertEqual(limiter.reserve(tabID: tab, mediaKey: "video:two", uptime: 100.4), .rejected(.inFlight))
        XCTAssertTrue(limiter.commit(current, mediaKey: "video:two", uptime: 101))
        XCTAssertEqual(limiter.reserve(tabID: tab, mediaKey: "video:two", uptime: 101.1), .rejected(.cooldown))
    }

    func testMediaCooldownKeyIgnoresTrackingAndPlayerRoute() {
        let video = "dQw4w9WgXcQ"
        let expected = "video:" + video
        for value in [
            "https://www.youtube.com/watch?v=\(video)",
            "https://www.youtube.com/watch?list=playlist&v=\(video)&t=30&pp=tracking#details",
            "https://m.youtube.com/shorts/\(video)",
            "https://www.youtube-nocookie.com/embed/\(video)?autoplay=1",
            "https://www.youtube.com/live/\(video)",
        ] { XCTAssertEqual(YouTubeAdNoticeRequest.mediaKey(for: URL(string: value)), expected, value) }
        XCTAssertNotEqual(YouTubeAdNoticeRequest.mediaKey(for: URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")), expected)
        XCTAssertEqual(YouTubeAdNoticeRequest.mediaKey(for: URL(string: "https://www.youtube.com/watch?v=invalid")), "youtube:watch")
        XCTAssertEqual(YouTubeAdNoticeRequest.mediaKey(for: URL(string: "https://www.youtube.com/?tracking=value")), "youtube:home")
        XCTAssertEqual(YouTubeAdNoticeRequest.mediaKey(for: URL(string: "https://youtube.com.evil.example/watch?v=\(video)")), "embed:youtube.com.evil.example")
    }
}
