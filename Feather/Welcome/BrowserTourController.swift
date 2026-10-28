import AppKit

/// Guides actual browser actions. It never navigates, bookmarks, or creates a
/// space on the user's behalf: those happen only through their real controls.
@MainActor
final class BrowserTourController {
    private weak var browser: BrowserWindowController?
    private weak var root: BrowserRootView?
    private unowned let state: BrowserState
    private let model: WindowState
    private let overlay = TourOverlayView()
    private let playback = WelcomePlaybackState()
    private var progress = TourProgress()
    private var onFinish: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var ending = false
    private var updating = false
    private var favoriteWasPresent = false
    private var favoriteTabID: UUID?
    private var lastPresentation: String?
    private var lastTarget: NSRect?

    init(browser: BrowserWindowController, root: BrowserRootView, state: BrowserState,
         model: WindowState, onFinish: @escaping () -> Void) {
        self.browser = browser
        self.root = root
        self.state = state
        self.model = model
        self.onFinish = onFinish
        playback.clickHandler = { BrowserClickSoundController.shared.playTourClick() }
    }

    func start() {
        guard let root else { return }
        if let window = browser?.window {
            let playback = playback
            BrowserClickSoundController.shared.registerTour(in: window) { [weak playback] in
                playback?.live == true && playback?.isMuted == false
            }
        }
        root.tourKeepsSidebarVisible = true
        root.render()
        root.layoutSubtreeIfNeeded()
        overlay.frame = root.bounds
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(overlay)
        root.onTourLayout = { [weak self] in self?.refresh() }
        overlay.onBegin = { [weak self] in
            self?.playback.playClick()
            self?.advance(.began)
        }
        overlay.onSkip = { [weak self] in self?.finish() }
        overlay.onNext = { [weak self] in
            guard let self else { return }
            if self.progress.step == .finished { self.finish() }
            else { self.playback.playClick(); self.advance(.next) }
        }
        overlay.onBack = { [weak self] in
            self?.playback.playClick()
            self?.advance(.back)
        }
        overlay.showIntro(playback: playback)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActivity() }
            })
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, self.progress.step == .intro, event.window === self.browser?.window,
               event.modifierFlags.contains(.command),
               ["t", "l"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") {
                self.advance(.began)
                return event
            }
            guard let self, event.window === self.browser?.window, event.keyCode == 53,
                  self.browser?.isTourCommandBarOpen != true else { return event }
            self.finish()
            return nil
        }
        refresh()
    }

    func commandBarOpened() { playback.playClick(); advance(.openedCommandBar) }
    func commandBarCommitted() { playback.playClick(); advance(.submittedAddress) }
    func commandBarClosed() { advance(.closedCommandBar) }

    /// Replaces the old detached modal only while this tour is practicing Spaces.
    func handleNewSpaceRequest() -> Bool {
        guard progress.step == .spaces else { return false }
        playback.playClick()
        overlay.showSpaceCreator(defaultName: "Work") { [weak self] name in
            guard let self, !self.ending, self.progress.step == .spaces else { return }
            self.state.switchToSpace(self.state.addSpace(named: name), in: self.model)
            self.advance(.createdSpace)
        }
        return true
    }

    func refresh() {
        guard !ending, !updating, let root else { return }
        updating = true
        defer { updating = false }
        updateActivity()
        browser?.layoutTourCommandBar()
        // The coach stays readable even if a short window's suggestion list
        // reaches it; the spotlight still passes clicks to the real field.
        if root.subviews.last !== overlay { root.addSubview(overlay, positioned: .above, relativeTo: nil) }
        if progress.step == .intro { return }
        if progress.step == .favorite, let tab = model.activeTab,
           state.favorite(of: tab) == nil,
           state.favorites.contains(where: { $0.isAtSavedPage(tab.url) }) {
            favoriteWasPresent = true
        }
        if progress.step == .favorite, !favoriteWasPresent,
           model.activeTab?.id == favoriteTabID, let tab = model.activeTab,
           state.favorite(of: tab) != nil {
            // Run after the current render, never mutate observation state inside it.
            DispatchQueue.main.async { [weak self] in self?.advance(.addedFavorite) }
        }
        let title: String
        let message: String
        let target: NSRect?
        var next = "Skip step"
        switch progress.step {
        case .intro: return
        case .newTab:
            title = "Open your first tab"
            message = "Click the highlighted New Tab button, or press ⌘T. You'll try the real browser as we go."
            target = anchor(.newTab, root: root)
        case .address:
            title = "Go somewhere"
            message = "Type a website or a search in the highlighted field, then press Return. Pick anywhere you like."
            target = browser?.tourCommandBarFrame
        case .favorite:
            if favoriteWasPresent {
                title = "Already one of your favorites"
                message = "This site is already saved. Favorites stay at the top of the sidebar in every Space. Continue to try Spaces."
                next = "Continue"
            } else if model.activeTab?.url?.host() != nil {
                title = "Keep this site close"
                message = "Click the highlighted star to add this site to Favorites. You can also press ⇧⌘D."
            } else {
                title = "Your everyday sites"
                message = "When a page is open, its star adds it to Favorites at the top of the sidebar. Open a page later to try it."
                next = "Continue"
            }
            target = anchor(.favorite, root: root) ?? anchor(.address, root: root)
        case .spaces:
            title = "Make a little Space"
            message = "Click the highlighted + to name a Space here. It keeps its own tabs and logins. This creates a real Space you can use."
            target = anchor(.spaces, root: root)
        case .finished:
            title = "You're ready to explore"
            message = "Your changes are yours to keep. ⌘T opens a tab, ⌘L opens the address field, and ⌘S brings the sidebar within reach. Replay this tour from Help anytime."
            target = nil
            next = "Finish tour"
        }
        let signature = "\(progress.step.rawValue)|\(title)|\(message)|\(next)"
        guard signature != lastPresentation || target != lastTarget else { return }
        lastPresentation = signature
        lastTarget = target
        overlay.showCoach(title: title, message: message, step: progress.step.rawValue,
                          total: 5, target: target, nextTitle: next, allowsNext: true)
    }

    private func anchor(_ target: TourTarget, root: NSView) -> NSRect? {
        guard let probe = TourAnchorView.find(target, in: root), probe.window === root.window else { return nil }
        let rect = root.convert(probe.bounds, from: probe)
        return rect.isEmpty ? nil : rect
    }

    private func advance(_ event: TourProgress.Event) {
        guard !ending else { return }
        let previous = progress.step
        progress.handle(event)
        guard previous != progress.step else { return }
        switch event {
        case .addedFavorite, .createdSpace: playback.playClick()
        default: break
        }
        if progress.step != .address { browser?.closeTourCommandBar() }
        if progress.step == .favorite {
            favoriteTabID = model.activeTab?.id
            favoriteWasPresent = model.activeTab.map { tab in
                state.favorite(of: tab) != nil || state.favorites.contains { $0.isAtSavedPage(tab.url) }
            } ?? false
        }
        lastPresentation = nil
        if progress.step == .address, browser?.isTourCommandBarOpen != true { browser?.showCommandBar(.newTab) }
        root?.render()
        root?.layoutSubtreeIfNeeded()
        refresh()
    }

    private func updateActivity() {
        let window = browser?.window
        let live = !ending && NSApp.isActive &&
            window?.isKeyWindow == true && window?.isVisible == true &&
            window?.occlusionState.contains(.visible) == true && window?.isMiniaturized == false
        if playback.live != live { playback.live = live }
    }

    func finish() {
        guard !ending else { return }
        ending = true
        playback.live = false
        playback.sound.stop()
        BrowserClickSoundController.shared.unregisterTour(in: browser?.window)
        browser?.closeTourCommandBar()
        root?.onTourLayout = nil
        overlay.hide()
        overlay.removeFromSuperview()
        root?.tourKeepsSidebarVisible = false
        root?.render()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        let completion = onFinish
        onFinish = nil
        completion?()
    }
}
