import AppKit
import SwiftUI
import WebKit
import os

private let sidebarLog = Logger(subsystem: "dev.nesbes.Feather", category: "Sidebar")

/// One browser window: tinted background, sidebar (SwiftUI) on the left,
/// content cards on the right, no toolbar.
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: WindowState
    unowned let state: BrowserState
    private let root: BrowserRootView
    private var loop: ObservationLoop?
    private var commandBar: CommandBarController?
    private var welcomeTour: BrowserTourController?
    private var launchSplash: LaunchSplashController?
    private weak var lastActiveTab: Tab?
    private var lastVisibleTabs: [Tab] = []
    var onClose: (() -> Void)?

    init(model: WindowState, state: BrowserState) {
        self.model = model
        self.state = state
        root = BrowserRootView(model: model, state: state)
        let frame = model.restoredFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 820)
        let window = BrowserWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.setAccessibilityIdentifier("feather.window.\(model.id.uuidString)")
        window.minSize = NSSize(width: 640, height: 420)
        window.contentView = root
        window.isReleasedWhenClosed = false
        if model.restoredFrame == nil { window.center() } else { window.setFrame(frame, display: false) }
        super.init(window: window)
        window.delegate = self
        root.onCommandBar = { [weak self] mode in self?.showCommandBar(mode) }
        window.onCycleTabs = { [weak self] offset in
            guard let self else { return }
            state.selectAdjacentTab(offset: offset, in: self.model)
        }
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func render() {
        root.render()
        let visible = model.visibleTabs
        for tab in lastVisibleTabs where !visible.contains(where: { $0 === tab }) {
            state.lifecycle.didHide(tab)
            if state.window(showing: tab) == nil { state.media.tabDidHide(tab) }
        }
        for tab in visible where !lastVisibleTabs.contains(where: { $0 === tab }) {
            state.media.tabDidShow(tab)
        }
        // A live tab shown again doesn't need its stand-in snapshot any more.
        for tab in visible where tab.controller?.hasPainted == true { tab.snapshotJPEG = nil }
        lastVisibleTabs = visible
        let active = model.activeTab
        window?.title = active?.displayTitle ?? "Feather"
        if active !== lastActiveTab {
            lastActiveTab = active
            // Keyboard focus follows the selected tab unless the command bar has it.
            if let webView = active?.webView, commandBar == nil, launchSplash == nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.launchSplash == nil else { return }
                    self.window?.makeFirstResponder(webView)
                }
            }
        }
        welcomeTour?.refresh()
    }

    var activeWebView: WKWebView? { model.activeTab?.webView }

    // MARK: Command bar

    func showCommandBar(_ mode: CommandBarMode) {
        guard let window else { return }
        commandBar?.close()
        let bar = CommandBarController(mode: mode, state: state, window: model)
        bar.onCommit = { [weak self] in self?.welcomeTour?.commandBarCommitted() }
        bar.onEmbeddedLayout = { [weak self] in self?.welcomeTour?.refresh() }
        bar.onClose = { [weak self, weak bar] in
            if self?.commandBar === bar { self?.commandBar = nil }
            if let webView = self?.activeWebView { self?.window?.makeFirstResponder(webView) }
            self?.welcomeTour?.commandBarClosed()
        }
        commandBar = bar
        if welcomeTour != nil {
            bar.showEmbedded(in: root, contentFrame: root.convert(root.contentFrameInWindow, from: nil))
        } else {
            bar.show(over: window, contentFrame: root.contentFrameInWindow)
        }
        welcomeTour?.commandBarOpened()
    }

    // MARK: In-window welcome

    /// Installed before the window is shown. Restored tabs load underneath it.
    func prepareLaunchSplash() {
        guard launchSplash == nil, let window else { return }
        launchSplash = LaunchSplashController(in: root, window: window)
    }

    func startLaunchSplash(onFinish: @escaping () -> Void) {
        guard let launchSplash else { onFinish(); return }
        window?.makeKeyAndOrderFront(nil)
        launchSplash.start { [weak self] in
            self?.launchSplash = nil
            if let self, self.commandBar == nil, let view = self.activeWebView {
                self.window?.makeFirstResponder(view)
            }
            onFinish()
        }
    }

    private func cancelLaunchSplash() {
        launchSplash?.cancel()
        launchSplash = nil
    }

    var isWelcomeTourActive: Bool { welcomeTour != nil }
    var isTourCommandBarOpen: Bool { commandBar != nil }
    var tourCommandBarFrame: NSRect? { commandBar?.embeddedFrame }
    func layoutTourCommandBar() {
        commandBar?.updateEmbeddedLayout(contentFrame: root.convert(root.contentFrameInWindow, from: nil))
    }

    func startWelcomeTour(onFinish: @escaping () -> Void) {
        cancelLaunchSplash()
        guard welcomeTour == nil else { return }
        commandBar?.close()
        let tour = BrowserTourController(browser: self, root: root, state: state, model: model) { [weak self] in
            self?.welcomeTour = nil
            self?.loop?.cancel()
            self?.loop = ObservationLoop { [weak self] in self?.render() }
            onFinish()
        }
        welcomeTour = tour
        tour.start()
    }

    func closeTourCommandBar() { commandBar?.close() }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        state.keyWindow = model
        state.lifecycle.factory.extensions.didFocusWindow(model)
    }

    func windowDidMove(_ notification: Notification) { rememberFrame() }

    func windowDidResize(_ notification: Notification) { rememberFrame() }

    private func rememberFrame() {
        guard let frame = window?.frame else { return }
        WindowFrames.frames[model.id] = frame
        state.scheduleSave()
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow {
            PeekWindowController.dismiss(in: closingWindow)
        }
        cancelLaunchSplash()
        welcomeTour?.finish()
        loop?.cancel()
        commandBar?.close()
        state.windowDidClose(model)
        onClose?()
    }

    // MARK: Actions (reached through the responder chain from the main menu)

    @objc func newTab(_ sender: Any?) { showCommandBar(.newTab) }

    @objc func openLocation(_ sender: Any?) { showCommandBar(.edit) }

    @objc func closeTab(_ sender: Any?) {
        if commandBar != nil, NSApp.keyWindow === window { commandBar?.close(); return }
        // AppKit can find this controller through the main window's responder
        // chain while an auxiliary window (Settings, for example) is key.
        // Close what the user is looking at before touching a browser tab.
        if let keyWindow = NSApp.keyWindow, keyWindow !== window {
            keyWindow.performClose(sender)
            return
        }
        if let tab = model.activeTab { state.close(tab) } else { window?.performClose(sender) }
    }

    @objc func reopenClosedTab(_ sender: Any?) { state.reopenClosedTab(in: model) }

    @objc func goBack(_ sender: Any?) { activeWebView?.goBack() }

    @objc func goForward(_ sender: Any?) { activeWebView?.goForward() }

    @objc func reloadPage(_ sender: Any?) {
        if let tab = model.activeTab, tab.webView == nil { state.lifecycle.ensureLive(tab) } else { activeWebView?.reload() }
    }

    @objc func reloadFromOrigin(_ sender: Any?) { activeWebView?.reloadFromOrigin() }

    @objc func stopLoading(_ sender: Any?) { activeWebView?.stopLoading() }

    @objc func togglePin(_ sender: Any?) { model.activeTab.map(state.togglePin) }

    @objc func toggleFavorite(_ sender: Any?) {
        guard let tab = model.activeTab else { return }
        if let favorite = state.favorite(of: tab) {
            state.removeFavorite(favorite, window: model)
        } else {
            state.addFavorite(from: tab, window: model)
        }
    }

    @objc func selectNextTab(_ sender: Any?) { state.selectAdjacentTab(offset: 1, in: model) }

    @objc func selectPreviousTab(_ sender: Any?) { state.selectAdjacentTab(offset: -1, in: model) }

    @objc func clearTabs(_ sender: Any?) { state.clearTabs(in: model) }

    @objc func toggleMute(_ sender: Any?) { model.activeTab.map(state.media.toggleMute) }

    @objc func listenToPage(_ sender: Any?) {
        guard let tab = model.activeTab else { return }
        ReadAloud.shared.toggle(tab, in: model)
    }

    @objc func copyMarkdownLink(_ sender: Any?) {
        guard let tab = model.activeTab, let url = tab.url else { return }
        let link = state.settings.cleanLinks ? LinkCleaner.clean(url) : url
        let title = tab.displayTitle.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[\(title)](\(link.absoluteString))", forType: .string)
        state.toasts.show("Copied link as Markdown", symbol: "link", in: model.id)
    }

    @objc func toggleReader(_ sender: Any?) {
        guard let tab = model.activeTab else { return }
        state.toggleReader(tab)
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) { state.selectTab(atIndex: sender.tag, in: model) }

    @objc func toggleSidebar(_ sender: Any?) {
        let settings = state.settings
        switch settings.sidebarMode {
        case .show:
            model.sidebarCollapsed.toggle()
            state.scheduleSave()
        case .autoHide:
            root.togglePeek()
        case .smart:
            // On a site, ⌘S is remembered for that site; elsewhere it just slides the sidebar in.
            guard let host = SmartSidebar.host(of: model.activeTab?.url) else { return root.togglePeek() }
            let hide = !root.isSidebarHidden
            let before = settings.sidebarOverrides[host]
            settings.setSidebarOverride(host, hidden: hide)
            state.toasts.show(hide ? "The sidebar will stay hidden on \(host)" : "The sidebar will stay on \(host)",
                              symbol: "sidebar.left", in: model.id, actions: [
                .init(title: "Undo") { settings.setSidebarOverride(host, hidden: before) },
            ], duration: 5)
        }
    }

    @objc func groupTabsNow(_ sender: Any?) {
        Task { await state.grouper.organize(model.space, window: model, manual: true) }
    }

    @objc func toggleSplitView(_ sender: Any?) { state.toggleSplit(in: model) }

    @objc func copyPageURL(_ sender: Any?) {
        guard let url = model.activeTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((state.settings.cleanLinks ? LinkCleaner.clean(url) : url).absoluteString, forType: .string)
    }

    @objc func zoomIn(_ sender: Any?) { activeWebView.map { $0.pageZoom = min(3, $0.pageZoom + 0.1) } }

    @objc func zoomOut(_ sender: Any?) { activeWebView.map { $0.pageZoom = max(0.3, $0.pageZoom - 0.1) } }

    @objc func actualSize(_ sender: Any?) { activeWebView?.pageZoom = 1 }

    @objc func findInPage(_ sender: Any?) { root.showFindBar(for: activeWebView) }

    @objc func findNextMatch(_ sender: Any?) { root.findAgain(backwards: false) }

    @objc func findPreviousMatch(_ sender: Any?) { root.findAgain(backwards: true) }

    @objc func toggleContentBlocking(_ sender: Any?) { root.toggleBlockingForActiveSite() }

    @objc func newSpace(_ sender: Any?) {
        if welcomeTour?.handleNewSpaceRequest() == true { return }
        guard let name = promptForText(title: "New Space", message: "Each space keeps its own tabs, cookies, and logins.",
                                       initial: "Space \(state.spaces.count + 1)") else { return }
        state.switchToSpace(state.addSpace(named: name), in: model)
    }

    @objc func switchSpaceByNumber(_ sender: NSMenuItem) {
        guard sender.tag < state.spaces.count else { return }
        state.switchToSpace(state.spaces[sender.tag], in: model)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeTab(_:)):
            item.title = NSApp.keyWindow === window && model.activeTab != nil ? "Close Tab" : "Close Window"
            return NSApp.keyWindow != nil
        case #selector(goBack(_:)): return model.activeTab?.canGoBack ?? false
        case #selector(goForward(_:)): return model.activeTab?.canGoForward ?? false
        case #selector(reopenClosedTab(_:)): return !state.recentlyClosed.isEmpty
        case #selector(clearTabs(_:)): return !model.space.tabs.isEmpty
        case #selector(listenToPage(_:)):
            item.title = ReadAloud.shared.isSpeaking ? "Stop Reading Aloud" : "Listen to Page"
            return ReadAloud.shared.isSpeaking || model.activeTab?.isLive == true
        case #selector(copyMarkdownLink(_:)): return model.activeTab?.url != nil
        case #selector(toggleReader(_:)):
            item.title = model.activeTab?.isReaderOpen == true ? "Hide Reader" : "Show Reader"
            return model.activeTab.map { $0.isReaderable || $0.isReaderOpen } ?? false
        case #selector(toggleMute(_:)):
            item.title = model.activeTab?.isMuted == true ? "Unmute Tab" : "Mute Tab"
            return model.activeTab != nil
        case #selector(togglePin(_:)):
            item.title = model.activeTab.map { state.space(of: $0)?.isPinned($0) ?? false } == true ? "Unpin Tab" : "Pin Tab"
            return model.activeTab.map { $0.favoriteID == nil } ?? false
        case #selector(toggleFavorite(_:)):
            item.title = model.activeTab?.favoriteID != nil ? "Remove from Favorites" : "Add to Favorites"
            return model.activeTab.map { $0.favoriteID != nil || $0.url?.scheme == "https" || $0.url?.scheme == "http" } ?? false
        case #selector(toggleSidebar(_:)):
            item.title = root.isSidebarHidden ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(groupTabsNow(_:)):
            return state.grouper.organizing == nil && model.space.looseTabs.count >= 2
        case #selector(toggleSplitView(_:)):
            item.title = model.secondary == nil ? "Split View" : "Close Split View"
            return model.primary != nil
        case #selector(switchSpaceByNumber(_:)): return item.tag < state.spaces.count
        case #selector(copyPageURL(_:)), #selector(findInPage(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(actualSize(_:)), #selector(reloadFromOrigin(_:)), #selector(stopLoading(_:)),
             #selector(toggleContentBlocking(_:)):
            return activeWebView != nil
        default: return true
        }
    }
}

/// Root view: lays out the sidebar and content, tints the window with the
/// space color, and reveals a collapsed sidebar when the pointer hits the left edge.
final class BrowserRootView: NSView {
    private let model: WindowState
    private unowned let state: BrowserState
    private let sidebar: NSHostingView<SidebarView>
    private let content = ContentAreaView()
    private let backdrop = GlassBackdropView()
    private let resizeHandle = SidebarResizeHandle()
    private let findBar = FindBar()
    private let toastHost: NSHostingView<ToastStack>
    private var sidebarRevealed = false
    /// Background for the sidebar while it peeks over the content.
    private var sidebarTint: CGColor?
    private var lastCollapsed: Bool?
    private let overlayShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 16
        return shadow
    }()
    private var edgeArea: NSTrackingArea?
    private var sidebarArea: NSTrackingArea?
    var onCommandBar: ((CommandBarMode) -> Void)?
    var onTourLayout: (() -> Void)?
    var tourKeepsSidebarVisible = false

    init(model: WindowState, state: BrowserState) {
        self.model = model
        self.state = state
        sidebar = NSHostingView(rootView: SidebarView(state: state, window: model, openCommandBar: { _ in }))
        toastHost = NSHostingView(rootView: ToastStack(center: state.toasts, windowID: model.id))
        super.init(frame: .zero)
        wantsLayer = true
        sidebar.sizingOptions = []
        sidebar.rootView = SidebarView(state: state, window: model, openCommandBar: { [weak self] in self?.onCommandBar?($0) })
        toastHost.sizingOptions = [.intrinsicContentSize]
        sidebar.wantsLayer = true
        [backdrop, content, sidebar, resizeHandle, findBar, toastHost].forEach(addSubview)
        findBar.isHidden = true
        content.onFocusSecondary = { [weak self] secondary in
            guard let self else { return }
            if let tab = secondary ? self.model.secondary : self.model.primary { self.state.select(tab, in: self.model) }
        }
        content.onRatioChange = { [weak self] ratio in
            self?.model.splitRatio = ratio
            self?.state.scheduleSave()
        }
        resizeHandle.onDrag = { [weak self] x in
            guard let self else { return }
            self.state.settings.sidebarWidth = Double(min(420, max(180, x)))
            self.needsLayout = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func render() {
        content.show(primary: model.primary, secondary: model.secondary, ratio: model.splitRatio,
                     focusSecondary: model.focusSecondary)
        findBar.retarget(to: model.activeTab?.webView)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let glass = state.settings.glassInterface
        // The site's own theme color, mixed into the space's, like Safari's tinted tab bar.
        let site = state.settings.matchSiteColor ? model.activeTab?.themeColor.flatMap { Self.opaque($0) } : nil
        let base = model.space.tint(dark: dark)
        let frameColor = site.flatMap { base.usingColorSpace(.sRGB)?.blended(withFraction: 0.8, of: $0) } ?? base
        backdrop.isHidden = !glass
        backdrop.apply(hue: model.space.hue, dark: dark, site: site)
        setBackground(glass ? .clear : frameColor)
        sidebarTint = frameColor.cgColor
        // Dark site colors get light sidebar text and the other way round; the page itself is unaffected.
        let siteAppearance: NSAppearance? = site == nil ? nil : NSAppearance(named: Self.isDark(frameColor) ? .darkAqua : .aqua)
        if sidebar.appearance?.name != siteAppearance?.name { sidebar.appearance = siteAppearance }
        content.cornerRadius = glass ? 16 : 10
        content.glass = glass
        _ = state.settings.sidebarWidth
        _ = state.toasts.toasts.count
        let hidden = !tourKeepsSidebarVisible && state.smartSidebar.hides(in: model, width: Double(bounds.width), previous: lastCollapsed)
        isSidebarHidden = hidden
        if !hidden { sidebarRevealed = false }
        updateTrafficLights()
        let collapseChanged = lastCollapsed != nil && lastCollapsed != hidden
        if collapseChanged {
            sidebarLog.info("Sidebar \(hidden ? "hidden" : "shown", privacy: .public) for \(SmartSidebar.host(of: self.model.activeTab?.url) ?? "-", privacy: .public)")
        }
        lastCollapsed = hidden
        if collapseChanged { applyLayout(animated: true) } else { needsLayout = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    /// Crossing the narrow-window width changes whether the smart sidebar hides.
    override func setFrameSize(_ newSize: NSSize) {
        let wasNarrow = frame.width < SidebarPolicy.narrowWidth
        super.setFrameSize(newSize)
        if (newSize.width < SidebarPolicy.narrowWidth) != wasNarrow { render() }
    }

    private var lastBackground: NSColor?

    private func setBackground(_ color: NSColor) {
        guard color != lastBackground else { return }
        let animate = lastBackground != nil
        lastBackground = color
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? 0.3 : 0
            context.allowsImplicitAnimation = animate
            layer?.backgroundColor = color.cgColor
        }
    }

    private static func opaque(_ color: NSColor) -> NSColor? {
        guard let srgb = color.usingColorSpace(.sRGB), srgb.alphaComponent > 0.5 else { return nil }
        return srgb.withAlphaComponent(1)
    }

    private static func isDark(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5
    }

    /// Whether the sidebar is out of the way right now (hidden by you, by the smart mode, or always).
    private(set) var isSidebarHidden = false

    /// ⌘S when the sidebar hides itself: slide it in over the page, or away again.
    func togglePeek() {
        setRevealed(!sidebarRevealed)
    }

    private var sidebarWidth: CGFloat { CGFloat(state.settings.sidebarWidth) }

    private var sidebarVisible: Bool { !isSidebarHidden || sidebarRevealed }

    var contentFrameInWindow: NSRect { convert(content.frame, to: nil) }

    override func layout() {
        super.layout()
        applyLayout(animated: false)
    }

    /// Sidebar collapse and peek slide over 0.2 s; everything else is placed directly.
    private func applyLayout(animated: Bool) {
        let inset: CGFloat = 8
        let collapsed = isSidebarHidden
        let leading = collapsed ? inset : sidebarWidth
        let contentFrame = NSRect(x: leading, y: inset, width: max(0, bounds.width - leading - inset),
                                  height: max(0, bounds.height - inset * 2))
        // A hidden sidebar waits just off the left edge so it can slide in.
        let sidebarFrame = NSRect(x: sidebarVisible ? 0 : -sidebarWidth - 20, y: 0, width: sidebarWidth, height: bounds.height)
        // Moving it offscreen must also remove its controls from the AX tree.
        sidebar.setAccessibilityHidden(!sidebarVisible)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                content.animator().frame = contentFrame
                sidebar.animator().frame = sidebarFrame
            }
        } else {
            content.frame = contentFrame
            sidebar.frame = sidebarFrame
        }
        backdrop.frame = bounds
        // Peeking over the content, the sidebar needs its own background and shadow.
        sidebar.layer?.backgroundColor = collapsed ? sidebarTint : nil
        sidebar.shadow = collapsed ? overlayShadow : nil
        let toastSize = toastHost.fittingSize
        toastHost.isHidden = toastSize.height < 1
        toastHost.frame = NSRect(x: contentFrame.midX - toastSize.width / 2, y: contentFrame.minY + 14,
                                 width: toastSize.width, height: toastSize.height)
        resizeHandle.frame = NSRect(x: sidebarWidth - 4, y: 0, width: 8, height: bounds.height)
        resizeHandle.isHidden = isSidebarHidden
        if !findBar.isHidden {
            let size = NSSize(width: 280, height: 30)
            findBar.frame = NSRect(x: contentFrame.maxX - size.width - 12, y: contentFrame.maxY - size.height - 12,
                                   width: size.width, height: size.height)
        }
        onTourLayout?()
    }

    // MARK: Collapsed sidebar reveal

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        [edgeArea, sidebarArea].compactMap { $0 }.forEach(removeTrackingArea)
        let edge = NSTrackingArea(rect: NSRect(x: 0, y: 0, width: 6, height: bounds.height),
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: ["area": "edge"])
        let side = NSTrackingArea(rect: NSRect(x: 0, y: 0, width: sidebarWidth + 12, height: bounds.height),
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: ["area": "sidebar"])
        addTrackingArea(edge)
        addTrackingArea(side)
        edgeArea = edge
        sidebarArea = side
    }

    override func mouseEntered(with event: NSEvent) {
        guard isSidebarHidden, event.trackingArea?.userInfo?["area"] as? String == "edge" else { return }
        setRevealed(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard isSidebarHidden, sidebarRevealed, event.trackingArea?.userInfo?["area"] as? String == "sidebar" else { return }
        setRevealed(false)
    }

    private func setRevealed(_ revealed: Bool) {
        sidebarRevealed = revealed
        updateTrafficLights()
        applyLayout(animated: true)
    }

    private func updateTrafficLights() {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(button)?.isHidden = !sidebarVisible
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrafficLights()
    }

    // MARK: Find

    func showFindBar(for webView: WKWebView?) {
        guard let webView else { return }
        let wasHidden = findBar.isHidden
        findBar.retarget(to: webView)
        findBar.isHidden = false
        if wasHidden { findBar.find(backwards: false) }
        needsLayout = true
        window?.makeFirstResponder(findBar.field)
        findBar.field.selectText(nil)
    }

    func findAgain(backwards: Bool) {
        findBar.find(backwards: backwards)
    }

    // MARK: Content blocking toggle

    func toggleBlockingForActiveSite() {
        guard let tab = model.activeTab, let host = tab.url?.host() else { return }
        let settings = state.settings
        settings.setAllowlisted(host, !settings.isAllowlisted(host))
        tab.webView?.reload()
    }
}

/// Drag target on the sidebar's trailing edge.
final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }
}

/// Small find-in-page field shown over the top right of the content.
final class FindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private(set) weak var webView: WKWebView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Find on page"
        field.setAccessibilityLabel("Find on page")
        field.setAccessibilityIdentifier("feather.find.query")
        field.setAccessibilityHelp("Type a search, Return to find the next match, or Escape to return to the page.")
        field.isEnabled = false
        field.sendsWholeSearchString = true
        field.delegate = self
        field.target = self
        field.action = #selector(search)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        field.frame = bounds
    }

    @objc private func search() {
        find(backwards: false)
    }

    /// Keep the query with the window, but always search its focused pane.
    func retarget(to webView: WKWebView?) {
        let hasTarget = webView != nil
        if field.isEnabled != hasTarget { field.isEnabled = hasTarget }
        guard self.webView !== webView else { return }
        self.webView = webView
        if !isHidden { find(backwards: false) }
    }

    func find(backwards: Bool) {
        guard let webView, !field.stringValue.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        webView.find(field.stringValue, configuration: configuration) { _ in }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            isHidden = true
            if let webView { window?.makeFirstResponder(webView) }
            return true
        }
        return false
    }
}

/// Modal text prompt used for naming spaces.
func promptForText(title: String, message: String, initial: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(string: initial)
    field.setAccessibilityLabel(title)
    field.setAccessibilityIdentifier("feather.prompt.input")
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let text = field.stringValue.trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
}

/// ⌃Tab and ⌃⇧Tab cycle tabs alongside the menu's ⇧⌘] and ⇧⌘[.
final class BrowserWindow: NSWindow {
    var onCycleTabs: ((Int) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, event.keyCode == 48, flags.subtracting(.shift) == .control, let onCycleTabs {
            onCycleTabs(flags.contains(.shift) ? -1 : 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
