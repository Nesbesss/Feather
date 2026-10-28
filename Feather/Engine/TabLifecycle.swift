import AppKit
import WebKit
import os

/// Retains running pages while WebKit throttles them in the background. Optional
/// unloading releases a web view and its live page state; saved interactionState
/// restores navigation history, not a JavaScript heap or an in-progress login.
final class TabLifecycle {
    unowned let state: BrowserState
    let blocker: ContentBlocker
    let factory: WebViewFactory
    private(set) var pressure: MemoryPressure = .normal
    private(set) var sleepCount = 0
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var evaluationScheduled = false
    private var evaluating = false
    private let log = Logger(subsystem: "dev.nesbes.Feather", category: "Lifecycle")


    init(state: BrowserState) {
        self.state = state
        blocker = ContentBlocker(settings: state.settings)
        factory = WebViewFactory(settings: state.settings, blocker: blocker)
        factory.adCatch.state = state
        factory.extensions.state = state
        factory.messages.handlers[UnsavedInputTracker.messageName] = { [unowned state] message in
            // Any frame can protect the page. Only a main-document commit clears
            // it, so a clean sibling iframe or prevented submit cannot erase edits.
            guard message.body as? Bool == true else { return }
            state.tab(showing: message.webView)?.hasUnsavedInput = true
        }
        factory.messages.handlers[LinkHoverScript.messageName] = { [unowned state] message in
            state.tab(showing: message.webView)?.hoveredLink = (message.body as? String).flatMap(URL.init(string:))
        }
        factory.messages.handlers[MediaScript.messageName] = { [unowned state] message in
            state.media.handle(message)
        }
        factory.messages.handlers[ReaderMode.messageName] = { [unowned state] message in
            guard let body = message.body as? [String: Any], let tab = state.tab(showing: message.webView) else { return }
            if let readerable = body["readerable"] as? Bool { tab.isReaderable = readerable }
            if let open = body["open"] as? Bool { tab.isReaderOpen = open }
            if let size = body["fontSize"] as? Double { state.settings.readerFontSize = size }
        }
        factory.messages.handlers[PageLayoutScript.messageName] = { [unowned state] message in
            state.smartSidebar.handle(message)
        }
        factory.messages.handlers[LoginFormScript.messageName] = { message in
            PasswordController.shared.handle(message)
        }
        log.info("Process-pool SPI available: \(FTWebKitSPI.isAvailable), pool: \(FTWebKitSPI.status(ofPool: self.factory.processPool).description, privacy: .public)")

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleEvaluation(delay: 0) }
        }
        timer?.tolerance = 5

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.pressureSource else { return }
                let event = source.data
                self.pressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
                self.log.notice("Memory pressure: \(String(describing: self.pressure))")
                if self.pressure != .normal { Task { await self.evaluate(pressure: self.pressure) } }
            }
        }
        source.resume()
        pressureSource = source
    }

    // MARK: Waking

    func ensureLive(_ tab: Tab) {
        guard tab.webView == nil, let space = state.space(of: tab) else { return }
        wake(tab, in: space)
    }

    @discardableResult
    func wake(_ tab: Tab, in space: Space, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let webView = tab.webView { return webView }
        let webView = factory.makeWebView(for: space, configuration: configuration, tab: tab)
        let controller = WebTabController(tab: tab, webView: webView, state: state)
        tab.controller = controller
        tab.webView = webView
        factory.extensions.bind(webView, to: tab, in: space)
        if tab.isMuted { state.media.applyMute(to: tab) }
        if configuration != nil {
            tab.pendingURL = nil
            return webView  // WebKit loads the opener's request itself.
        }
        if let saved = tab.interactionState {
            webView.interactionState = saved
            tab.interactionState = nil
        }
        if let url = tab.pendingURL {
            webView.open(url)
        } else if webView.url == nil, let url = tab.url {
            webView.open(url)
        }
        tab.pendingURL = nil
        return webView
    }

    /// Loads a URL in a tab, keeping its history whether it is live or asleep.
    func load(_ url: URL, fallbacks: [URL], in tab: Tab) {
        tab.fallbackURLs = fallbacks
        tab.url = url
        if let webView = tab.webView {
            webView.open(url)
        } else {
            tab.pendingURL = url
            ensureLive(tab)
        }
    }

    // MARK: Sleeping

    /// Takes the snapshot a tab shows while waking from sleep. Done as soon as the
    /// tab is hidden: WebKit may suspend a hidden page later, and a suspended
    /// page can't render one.
    func didHide(_ tab: Tab) {
        // Retained pages need no screenshot or JPEG work on every tab switch.
        guard state.settings.policy != .never,
              let webView = tab.webView, state.window(showing: tab) == nil else { return }
        Task { await captureSnapshot(of: tab, webView: webView) }
    }

    private func captureSnapshot(of tab: Tab, webView: WKWebView) async {
        let image = await firstOf(timeout: 1.5, default: nil) {
            try? await webView.takeSnapshot(configuration: Self.snapshotConfiguration(for: webView))
        }
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let jpeg = await Task.detached(priority: .utility) { Self.jpeg(cgImage) }.value
        if tab.webView === webView, state.window(showing: tab) == nil { tab.snapshotJPEG = jpeg }
    }

    /// Saves the tab's state, then releases its web view and so its WebContent process.
    func sleep(_ tab: Tab, reason: SleepDecision.Reason) async {
        guard let webView = tab.webView, canUnload(tab, webView: webView, reason: reason) else { return }
        let lastActive = tab.lastActive
        let documentID = tab.documentID
        let configuredPolicy = state.settings.policy
        if tab.snapshotJPEG == nil { await captureSnapshot(of: tab, webView: webView) }
        // Audio lookup and snapshotting yield. Recheck every synchronous guard
        // after both, including a select-then-hide or a newly committed document.
        let audible = await isAudible(webView)
        guard !audible, tab.lastActive == lastActive, tab.documentID == documentID,
              reason == .manual || state.settings.policy == configuredPolicy,
              canUnload(tab, webView: webView, reason: reason) else { return }
        tab.interactionState = webView.interactionState as? Data
        release(tab)
        sleepCount += 1
        log.info("Slept \(tab.displayTitle, privacy: .public) (\(reason.rawValue, privacy: .public)), snapshot \(tab.snapshotJPEG?.count ?? 0) bytes")
    }

    /// Releases a tab's web view without a snapshot, e.g. when it is closed.
    func discard(_ tab: Tab, keepingState: Bool = false) {
        if keepingState, let webView = tab.webView {
            tab.interactionState = webView.interactionState as? Data
        }
        release(tab)
    }

    func sleepAllBackgroundTabs() async {
        for tab in state.liveTabs where state.window(showing: tab) == nil {
            await sleep(tab, reason: .manual)
        }
    }

    /// Final destruction boundary, also used by the explicit memory-panel action.
    private func canUnload(_ tab: Tab, webView: WKWebView, reason: SleepDecision.Reason) -> Bool {
        tab.webView === webView && state.window(showing: tab) == nil
            && (reason == .manual || state.settings.policy != .never)
            && !tab.hasUnsavedInput && !tab.isLoading && !webView.isLoading
            && webView.cameraCaptureState == .none && webView.microphoneCaptureState == .none
            && !tab.autoPictureInPicture && tab.media?.inPictureInPicture != true
            && !(tab.isMuted && tab.media?.playing == true)
            && !FTWebKitSPI.isPlayingAudio(webView)
            && !state.popups.contains { $0.opener === tab }
    }

    private func release(_ tab: Tab) {
        guard let webView = tab.webView else { return }
        factory.extensions.untrack(webView)
        tab.controller?.invalidate()
        tab.controller = nil
        webView.removeFromSuperview()
        tab.webView = nil
        tab.isLoading = false
        tab.progress = 0
        tab.isPlayingAudio = false
        tab.footprint = nil
        tab.media = nil
        tab.mediaFrame = nil
        tab.autoPictureInPicture = false
    }

    // MARK: Policy

    /// Runs the sleep policy soon, coalescing bursts such as rapid tab switches.
    func scheduleEvaluation(delay: TimeInterval = 1) {
        guard !evaluationScheduled else { return }
        evaluationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.evaluationScheduled = false
            Task { await self.evaluate(pressure: self.pressure) }
        }
    }

    func evaluate(pressure: MemoryPressure) async {
        guard !evaluating else { return }
        evaluating = true
        defer { evaluating = false }

        let configuredPolicy = state.settings.policy
        let saving = configuredPolicy != .never && state.settings.batterySaver && PowerState.savesEnergy
        if state.batterySaverActive != saving { state.batterySaverActive = saving }
        guard configuredPolicy != .never else {
            // Reclaim idle cached processes under pressure without destroying pages.
            if pressure == .critical { FTWebKitSPI.clearWebProcessCache(ofPool: factory.processPool) }
            return
        }
        let policy = saving ? configuredPolicy.onBattery() : configuredPolicy
        let now = Date()
        let shownSpaces = Set(state.windows.map(\.space.id))
        let liveCount = state.liveTabs.count
        var facts: [TabFacts] = []
        var documents: [UUID: (view: WKWebView, id: UUID)] = [:]
        for space in state.spaces {
            for tab in space.allTabs {
                guard let webView = tab.webView else { continue }
                documents[tab.id] = (webView, tab.documentID)
                let visible = state.window(showing: tab) != nil
                var fact = TabFacts(id: tab.id, isLive: true, isVisible: visible, lastActive: tab.lastActive,
                                    inVisibleSpace: shownSpaces.contains(space.id), footprint: tab.footprint)
                fact.hasUnsavedInput = tab.hasUnsavedInput
                fact.isLoading = tab.isLoading || webView.isLoading
                fact.hasActivePopup = state.popups.contains { $0.opener === tab }
                // Only ask WebKit about tabs the policy might actually put to sleep.
                let idleLimit = fact.inVisibleSpace ? policy.sleepAfter : policy.hiddenSpaceSleepAfter
                let mightSleep = pressure != .normal || liveCount > policy.maxLiveTabs
                    || now.timeIntervalSince(tab.lastActive) >= idleLimit
                    || (policy.footprintLimit.map { (tab.footprint ?? 0) > $0 } ?? false)
                if !visible && mightSleep {
                    fact.isCapturingMedia = webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
                    // A video in picture-in-picture, or one the user muted, is still being watched.
                    let watched = tab.autoPictureInPicture || tab.media?.inPictureInPicture == true
                        || (tab.isMuted && tab.media?.playing == true)
                    fact.isPlayingMedia = watched ? true : await isAudible(webView)
                }
                facts.append(fact)
            }
        }
        for decision in policy.tabsToSleep(facts, now: now, pressure: pressure) {
            if let tab = state.tab(id: decision.id),
               state.settings.policy == configuredPolicy,
               let original = facts.first(where: { $0.id == decision.id }), tab.lastActive == original.lastActive,
               let document = documents[tab.id], tab.webView === document.view, tab.documentID == document.id {
                await sleep(tab, reason: decision.reason)
            }
        }
        if pressure == .critical { FTWebKitSPI.clearWebProcessCache(ofPool: factory.processPool) }
    }

    /// Only audible playback keeps a tab awake; muted autoplay videos don't.
    private func isAudible(_ webView: WKWebView) async -> Bool {
        if FTWebKitSPI.canDetectAudio(webView) { return FTWebKitSPI.isPlayingAudio(webView) }
        return await firstOf(timeout: 0.5, default: true) { await webView.requestMediaPlaybackState() == .playing }
    }

    /// The operation's result, or `value` if it hasn't finished within `timeout`.
    /// The operation keeps running; only its late result is ignored.
    private func firstOf<T>(timeout: TimeInterval, default value: T, _ operation: @escaping () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            var resumed = false
            Task {
                let result = await operation()
                if !resumed { resumed = true; continuation.resume(returning: result) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !resumed { resumed = true; continuation.resume(returning: value) }
            }
        }
    }

    // MARK: Snapshots

    private static func snapshotConfiguration(for webView: WKWebView) -> WKSnapshotConfiguration {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        // Reduced size: it only stands in for the page for a moment while it wakes.
        configuration.snapshotWidth = NSNumber(value: min(Double(webView.bounds.width) * 0.6, 900))
        return configuration
    }

    private nonisolated static func jpeg(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.55])
    }
}

extension WKWebView {
    /// Loads a web address, or a local file with read access to its folder (for its images and styles).
    func open(_ url: URL) {
        if url.isFileURL {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            load(URLRequest(url: url))
        }
    }
}
