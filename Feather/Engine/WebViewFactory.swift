import AppKit
import Observation
import WebKit

/// Builds web views. All of them share one lean process pool; each space has
/// its own website data store, like Safari's per-profile configuration
/// (`+[WebKitPreferencesManager _webViewConfigurationForBrowsingMode:…]`).
final class WebViewFactory {
    /// A WKProcessPool, configured by `FTWebKitSPI`.
    let processPool: NSObject
    private let settings: AppSettings
    private let blocker: ContentBlocker
    /// Receives every Feather page-script message; handlers are set by `TabLifecycle`.
    let messages = ScriptMessageRouter()
    let adCatch: YouTubeAdCatchHandler
    let extensions: BrowserExtensionManager
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    private lazy var ephemeralStore = WKWebsiteDataStore.nonPersistent()
    /// Benchmarks use a non-persistent store: nothing written, nothing cached between runs.
    var ephemeral = false

    /// "Version/27.0 Safari/605.1.15" so sites serve their Safari experience.
    static let userAgentSuffix: String = {
        let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let version = info?["CFBundleShortVersionString"] as? String ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    init(settings: AppSettings, blocker: ContentBlocker) {
        self.settings = settings
        self.blocker = blocker
        adCatch = YouTubeAdCatchHandler(settings: settings)
        extensions = BrowserExtensionManager()
        // Keep normal back/forward caching. Disabling it exposes a stuck native
        // loading state after COOP history navigation on the tested WebKit build.
        // The pool still avoids idle process caching and automatic prewarming.
        processPool = FTWebKitSPI.makeProcessPoolLean(false)
    }

    func dataStore(for space: Space) -> WKWebsiteDataStore {
        if ephemeral { return ephemeralStore }
        guard let id = space.dataStoreID else { return .default() }
        if let store = dataStores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id)
        dataStores[id] = store
        return store
    }

    func forgetDataStore(_ id: UUID) {
        dataStores[id] = nil
    }

    /// Call after native-rule readiness and immediately before permitting a main navigation.
    @discardableResult
    func updateProtection(for url: URL, in webView: WKWebView) -> YouTubeBlockingPolicy {
        let policy = YouTubeBlockingPolicy(blockContent: settings.blockContent, allowlistedHosts: settings.allowlistedHosts,
                                          topLevelHost: url.host())
        let controller = webView.configuration.userContentController
        YouTubeAdBlocker.refresh(in: controller, policy: policy)
        blocker.setBlocking(blocker.shouldBlock(host: url.host()), for: controller)
        return policy
    }

    func navigationProtection() -> WebNavigationProtection {
        WebNavigationProtection(factory: self, blocker: blocker)
    }

    /// `configuration` is WebKit's own when a page opens a window; it must be used as is.
    func makeWebView(for space: Space, configuration: WKWebViewConfiguration? = nil, tab: Tab? = nil) -> WKWebView {
        // WebKit can inherit the opener's controller. Give the child its own policy
        // without changing WebKit's configuration identity or opener relationship.
        if let configuration {
            configuration.userContentController = copyUserContent(configuration.userContentController)
            configuration.preferences.inactiveSchedulingPolicy = .throttle
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                configuration: configuration ?? makeConfiguration(for: space))
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        adCatch.track(webView)
        if let tab { extensions.bind(webView, to: tab, in: space) }
        else { extensions.track(webView, in: space) }
        return webView
    }

    private func copyUserContent(_ inherited: WKUserContentController) -> WKUserContentController {
        let controller = WKUserContentController()
        let scripts = inherited.userScripts
        scripts.forEach(controller.addUserScript)
        // These are all non-router handlers Feather installs. Public WebKit cannot
        // enumerate handlers, so reconnect the known bridges used by copied scripts.
        messages.install(into: controller)
        if scripts.contains(where: { $0.source.contains(CookieConsent.messageName) }) {
            controller.addScriptMessageHandler(CookieConsent.shared, contentWorld: .defaultClient, name: CookieConsent.messageName)
        }
        if scripts.contains(where: { $0.source.contains(YouTubeExtras.messageName) }) {
            controller.addScriptMessageHandler(YouTubeExtras.shared, contentWorld: .defaultClient, name: YouTubeExtras.messageName)
        }
        blocker.install(into: controller)
        YouTubeAdBlocker.refresh(in: controller, policy: YouTubeBlockingPolicy(blockContent: settings.blockContent,
                                                                             allowlistedHosts: settings.allowlistedHosts,
                                                                             topLevelHost: nil))
        adCatch.install(into: controller)
        return controller
    }

    func makeConfiguration(for space: Space) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        FTWebKitSPI.assignProcessPool(processPool, to: configuration)
        configuration.websiteDataStore = dataStore(for: space)
        configuration.webExtensionController = extensions.controller(for: space, dataStore: configuration.websiteDataStore,
                                                                    ephemeral: ephemeral)
        // One controller per web view, so blocking can be switched off per site.
        let userContent = WKUserContentController()
        userContent.addUserScript(UnsavedInputTracker.script)
        userContent.addUserScript(LoginFormScript.script)
        userContent.addUserScript(LinkHoverScript.script)
        userContent.addUserScript(MediaScript.script)
        userContent.addUserScript(ReaderMode.readerableScript)
        userContent.addUserScript(PageLayoutScript.script)
        Passkeys.install(into: userContent)
        CookieConsent.shared.install(into: userContent, enabled: settings.declineCookiePopups)
        YouTubeExtras.shared.install(into: userContent, settings: settings)
        YouTubeAdBlocker.refresh(in: userContent, policy: YouTubeBlockingPolicy(blockContent: settings.blockContent,
                                                                             allowlistedHosts: settings.allowlistedHosts,
                                                                             topLevelHost: nil))
        adCatch.install(into: userContent)
        messages.install(into: userContent)
        blocker.install(into: userContent)
        configuration.userContentController = userContent
        configuration.applicationNameForUserAgent = Self.userAgentSuffix
        configuration.mediaTypesRequiringUserActionForPlayback = settings.blockAutoplay ? .all : .audio
        configuration.preferences.isElementFullscreenEnabled = true
        // Keep fetches, timers and app state alive off-window, with WebKit's CPU
        // throttling. The default .suspend pauses JavaScript in detached views.
        configuration.preferences.inactiveSchedulingPolicy = .throttle
        FTWebKitSPI.applyThrottling(to: configuration.preferences)
        FTWebKitSPI.enablePictureInPicture(for: configuration.preferences)
        FTWebKitSPI.setPageCacheEnabled(true, preferences: configuration.preferences)
        return configuration
    }
}

/// Never treats page-world provenance as trusted. The only permitted effect is
/// a bounded fixed notice in the currently foreground browser tab.
final class YouTubeAdCatchHandler: NSObject, WKScriptMessageHandler {
    weak var state: BrowserState?
    private(set) var noticesShown = 0
    private(set) var noticeDelivery: [String: Int] = ["inPageShown": 0, "nativeFallbackShown": 0, "indeterminate": 0]
    private let settings: AppSettings
    private var limiter = YouTubeAdCatchLimiter()
    private let navigationIDs = NSMapTable<WKWebView, NSUUID>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private let webViews = NSHashTable<WKWebView>.weakObjects()
    private var nativeToastIDs: Set<UUID> = []
    private var popupPreference = YouTubeAdNoticePreference()

    private final class Evaluation {
        private var continuation: CheckedContinuation<YouTubeAdNoticeOutcome, Never>?
        private var completion = YouTubeAdNoticeCompletion()
        init(_ continuation: CheckedContinuation<YouTubeAdNoticeOutcome, Never>) { self.continuation = continuation }
        func complete(_ outcome: YouTubeAdNoticeOutcome) {
            guard completion.accept(outcome) else { return }
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        observePopupPreference()
    }

    func track(_ webView: WKWebView) {
        webViews.add(webView)
        // New documents start disabled. A validated catch enables its current
        // revision; preference changes update already-loaded documents in place.
    }

    private func synchronizePopupPreference() {
        updatePopupPreference(enabled: settings.showYouTubeAdCatchPopups)
    }

    private func updatePopupPreference(enabled: Bool) {
        guard popupPreference.update(enabled: enabled) else { return }
        cancelPopupPresentations()
    }

    private func observePopupPreference() {
        let enabled = withObservationTracking {
            settings.showYouTubeAdCatchPopups
        } onChange: { [weak self] in
            // Observable changes are delivered before the new value is stored.
            // Cancel now, then read/rearm on the next main-actor turn. This also
            // catches a rapid off/on cycle coalesced into that same turn.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.popupPreference.invalidate()
                self.cancelPopupPresentations()
                Task { @MainActor [weak self] in self?.observePopupPreference() }
            }
        }
        // Side effects stay outside tracking, so unrelated toast updates cannot
        // accidentally become dependencies of this preference observer.
        updatePopupPreference(enabled: enabled)
    }

    private func cancelPopupPresentations() {
        // Any preference transition invalidates old tickets and queued callbacks.
        limiter = YouTubeAdCatchLimiter()
        if let state {
            for id in nativeToastIDs { state.toasts.dismiss(id) }
        }
        nativeToastIDs.removeAll()
        for webView in webViews.allObjects { applyPopupPreference(to: webView) }
    }

    private func applyPopupPreference(to webView: WKWebView) {
        webView.callAsyncJavaScript("return globalThis.__featherYouTubeAdNotice?.setEnabled(enabled, revision) ?? false;",
                                    arguments: ["enabled": popupPreference.enabled, "revision": popupPreference.revision],
                                    in: nil, in: .defaultClient, completionHandler: nil)
    }

    func install(into controller: WKUserContentController) {
        guard controller.userScripts.contains(where: { $0.source.hasPrefix(YouTubeScriptComposition.scriptMarker) }) else { return }
        controller.add(self, contentWorld: .page, name: YouTubeAdCatchMessage.name)
    }

    func invalidate(in webView: WKWebView) {
        navigationIDs.setObject(NSUUID(), forKey: webView)
        if let tab = state?.tab(showing: webView) { limiter.cancel(tabID: tab.id) }
    }

    func urlDidChange(in webView: WKWebView, from previousURL: URL?) {
        guard previousURL != webView.url,
              !YouTubeAdNoticeRequest.isSameOriginYouTube(previousURL, webView.url) else { return }
        invalidate(in: webView)
    }

    private func navigationID(for webView: WKWebView) -> UUID {
        if let existing = navigationIDs.object(forKey: webView) { return existing as UUID }
        let id = NSUUID()
        navigationIDs.setObject(id, forKey: webView)
        return id as UUID
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        incrementDelivery("received")
        synchronizePopupPreference()
        guard settings.showYouTubeAdCatchPopups else { incrementDelivery("drop_popupsDisabled"); return }
        guard YouTubeAdCatchMessage.isValid(message.body) else { incrementDelivery("drop_schema"); return }
        guard let webView = message.webView else { incrementDelivery("drop_detached"); return }
        guard ["http", "https"].contains(message.frameInfo.securityOrigin.protocol.lowercased()) else {
            incrementDelivery("drop_origin"); return
        }
        guard let context = foregroundContext(for: webView, frameHost: message.frameInfo.securityOrigin.host) else { return }
        let tab = context.tab
        let preferenceRevision = popupPreference.revision
        let ticket: YouTubeAdCatchLimiter.Ticket
        switch limiter.reserve(tabID: tab.id, mediaKey: YouTubeAdNoticeRequest.mediaKey(for: webView.url),
                               uptime: ProcessInfo.processInfo.systemUptime) {
        case .reserved(let reserved): ticket = reserved
        case .rejected(let reason): incrementDelivery("drop_" + reason.rawValue); return
        }
        incrementDelivery("admitted")

        // A YouTube embed in another site has no top-level YouTube logo to anchor to.
        guard YouTubeBlockingPolicy.isYouTube(webView.url?.host()) else {
            if showNativeNotice(in: context.window, state: context.state, preferenceRevision: preferenceRevision) {
                limiter.commit(ticket, mediaKey: YouTubeAdNoticeRequest.mediaKey(for: webView.url), uptime: ProcessInfo.processInfo.systemUptime)
            } else { limiter.release(ticket, uptime: ProcessInfo.processInfo.systemUptime) }
            return
        }
        let request = YouTubeAdNoticeRequest(navigationID: navigationID(for: webView), topLevelURL: webView.url,
                                            frameHost: message.frameInfo.securityOrigin.host)
        Task { @MainActor [weak self, weak webView, weak tab] in
            guard let self else { return }
            defer { self.limiter.release(ticket, uptime: ProcessInfo.processInfo.systemUptime) }
            guard let webView, let tab else { self.incrementDelivery("drop_detached"); return }
            guard let current = self.foregroundContext(for: webView, frameHost: request.frameHost), current.tab === tab else { return }
            guard self.popupPreference.permits(revision: preferenceRevision) else { self.incrementDelivery("drop_preferenceChanged"); return }
            guard request.isCurrent(navigationID: self.navigationID(for: webView), topLevelURL: webView.url,
                                    policy: current.policy) else { self.incrementDelivery("drop_beforeShowStale"); return }
            let outcome = await self.showInPageNotice(in: webView, preferenceRevision: preferenceRevision)
            self.incrementDelivery("outcome_" + outcome.rawValue)
            if outcome.result == .indeterminate {
                self.incrementDelivery("indeterminate")
                self.limiter.release(ticket, quarantineMediaKey: YouTubeAdNoticeRequest.mediaKey(for: webView.url),
                                     uptime: ProcessInfo.processInfo.systemUptime)
            }
            guard let latest = self.foregroundContext(for: webView, frameHost: request.frameHost), latest.tab === tab else { return }
            guard self.popupPreference.permits(revision: preferenceRevision) else { self.incrementDelivery("drop_preferenceChanged"); return }
            guard request.isCurrent(navigationID: self.navigationID(for: webView), topLevelURL: webView.url,
                                    policy: latest.policy) else { self.incrementDelivery("drop_afterShowStale"); return }
            switch outcome.result {
            case .shown:
                self.incrementDelivery("inPageShown")
                self.recordNoticeShown()
                self.limiter.commit(ticket, mediaKey: YouTubeAdNoticeRequest.mediaKey(for: webView.url),
                                    uptime: ProcessInfo.processInfo.systemUptime)
            case .notShown:
                if self.showNativeNotice(in: latest.window, state: latest.state, preferenceRevision: preferenceRevision) {
                    self.limiter.commit(ticket, mediaKey: YouTubeAdNoticeRequest.mediaKey(for: webView.url),
                                        uptime: ProcessInfo.processInfo.systemUptime)
                }
            case .indeterminate:
                // The UI may already be visible; missing acknowledgement is not
                // proof that another presentation is needed.
                break
            }
        }
    }

    private func foregroundContext(for webView: WKWebView, frameHost: String)
        -> (state: BrowserState, tab: Tab, window: WindowState, policy: YouTubeBlockingPolicy)? {
        synchronizePopupPreference()
        guard settings.showYouTubeAdCatchPopups else { incrementDelivery("drop_popupsDisabled"); return nil }
        guard let state, let tab = state.tab(showing: webView), let window = state.window(showing: tab) else {
            incrementDelivery("drop_detached"); return nil
        }
        guard window === state.keyWindow, window.activeTab === tab,
              NSApp.isActive, webView.window?.isKeyWindow == true else {
            incrementDelivery("drop_foreground"); return nil
        }
        let policy = YouTubeBlockingPolicy(blockContent: settings.blockContent, allowlistedHosts: settings.allowlistedHosts,
                                          topLevelHost: webView.url?.host())
        guard policy.shouldProtect(frameHost: frameHost) else { incrementDelivery("drop_policy"); return nil }
        return (state, tab, window, policy)
    }

    @discardableResult
    private func showNativeNotice(in window: WindowState, state: BrowserState, preferenceRevision: Int) -> Bool {
        synchronizePopupPreference()
        guard settings.showYouTubeAdCatchPopups, popupPreference.permits(revision: preferenceRevision) else {
            incrementDelivery("drop_popupsDisabled"); return false
        }
        let id = state.toasts.show("Caught that ad for you!", symbol: "checkmark.shield.fill", in: window.id,
                                   duration: 2.5, compact: true)
        nativeToastIDs.insert(id)
        nativeToastIDs.formIntersection(Set(state.toasts.toasts.map(\.id)))
        incrementDelivery("nativeFallbackShown")
        recordNoticeShown()
        return true
    }

    private func incrementDelivery(_ key: String) {
        noticeDelivery[key] = min((noticeDelivery[key] ?? 0) + 1, 1_000_000)
    }

    private func recordNoticeShown() {
        noticesShown = min(noticesShown + 1, 1_000_000)
    }

    private func showInPageNotice(in webView: WKWebView, preferenceRevision: Int) async -> YouTubeAdNoticeOutcome {
        await withCheckedContinuation { continuation in
            let evaluation = Evaluation(continuation)
            // Budget: 1s initial parsing + 150ms API wait + 6s UI settling +
            // 420ms entry and 350ms stable painted acknowledgement, with margin.
            // An ambiguous timeout never causes another presentation.
            let timeout = DispatchWorkItem {
                MainActor.assumeIsolated { evaluation.complete(.timedOut) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.5, execute: timeout)
            // Do not start a late queued invocation after the native fallback deadline.
            // Once started, notice.js bounds its settling wait and visible dwell.
            let source = """
                if (Date.now() > latestStart) return 'startExpired';
                const origin = location.origin, wall = Date.now(), started = performance.now();
                const elapsed = () => Math.max(Date.now() - wall, performance.now() - started);
                let waited = false;
                while (typeof globalThis.__featherYouTubeAdNotice?.show !== 'function') {
                  if (document.hidden || location.origin !== origin) return 'declined';
                  if (elapsed() >= 150) return 'unavailable';
                  waited = true;
                  await new Promise(resolve => setTimeout(resolve, 15));
                }
                if (document.hidden || location.origin !== origin) return 'declined';
                if (waited && elapsed() >= 150) return 'unavailable';
                if (globalThis.__featherYouTubeAdNotice.setEnabled(true, preferenceRevision) !== true) return 'declined';
                const shown = await globalThis.__featherYouTubeAdNotice.show();
                return shown === true ? 'shown' : shown === false ? 'declined' : 'invalidResult';
                """
            webView.callAsyncJavaScript(source, arguments: ["latestStart": Date().timeIntervalSince1970 * 1_000 + 1_000,
                                                          "preferenceRevision": preferenceRevision],
                                        in: nil, in: .defaultClient) { result in
                MainActor.assumeIsolated {
                    timeout.cancel()
                    switch result {
                    case .success(let value):
                        // Strings come only from the fixed wrapper above, not page data.
                        let outcome = (value as? String).flatMap(YouTubeAdNoticeOutcome.init(rawValue:)) ?? .invalidResult
                        evaluation.complete(outcome)
                    case .failure: evaluation.complete(.evaluationFailed)
                    }
                }
            }
        }
    }
}

/// Shared by tabs, previews, and popup delegates so every document uses the same
/// readiness, current-settings, and back/forward-cache policy checks.
final class WebNavigationProtection {
    private unowned let factory: WebViewFactory
    private let blocker: ContentBlocker
    private weak var protectedWebView: WKWebView?
    private var generation = 0
    private var pendingCacheValidation: (generation: Int, stamp: String)?

    init(factory: WebViewFactory, blocker: ContentBlocker) {
        self.factory = factory
        self.blocker = blocker
    }

    func invalidate() {
        generation += 1
        pendingCacheValidation = nil
        if let protectedWebView { factory.adCatch.invalidate(in: protectedWebView) }
    }

    func prepare(for action: WKNavigationAction, in webView: WKWebView, delegate: WKNavigationDelegate) async -> Bool {
        // A nil target is an opener's new-window request; the returned child web
        // view's own main-frame navigation applies its independent controller policy.
        guard action.targetFrame?.isMainFrame == true else { return true }
        guard let url = action.request.url else { return true }
        protectedWebView = webView
        factory.adCatch.invalidate(in: webView)
        generation += 1
        let current = generation
        pendingCacheValidation = nil
        await factory.extensions.prepare(in: webView)
        await blocker.prepare()
        guard current == generation, webView.navigationDelegate === delegate else { return false }
        let policy = factory.updateProtection(for: url, in: webView)
        if action.navigationType == .backForward, let stamp = try? YouTubeScriptComposition.policyStamp(policy) {
            pendingCacheValidation = (current, stamp)
        }
        return true
    }

    func didFinish(in webView: WKWebView, delegate: WKNavigationDelegate) {
        guard let pending = pendingCacheValidation, pending.generation == generation else { return }
        pendingCacheValidation = nil
        Task { @MainActor [weak self, weak webView, weak delegate] in
            guard let self, let webView, let delegate, pending.generation == self.generation,
                  webView.navigationDelegate === delegate else { return }
            let stamp = try? await webView.callAsyncJavaScript("return globalThis.__featherYouTubePolicyStamp || null;",
                                                             arguments: [:], in: nil, contentWorld: .defaultClient)
            guard pending.generation == self.generation, webView.navigationDelegate === delegate else { return }
            if stamp as? String != pending.stamp { webView.reload() }
        }
    }
}
