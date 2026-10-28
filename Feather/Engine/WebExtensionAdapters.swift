import AppKit
import WebKit

private func extensionAdapterError(_ message: String) -> NSError {
    NSError(domain: "dev.nesbes.Feather.WebExtension", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}

/// A stable extension tab identity. The model survives WebKit views sleeping;
/// auxiliary views represent extension pages, popups, and Peek windows.
@MainActor
final class WebExtensionTabAdapter: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    weak var state: BrowserState?
    weak var auxiliaryWebView: WKWebView?
    weak var owner: WebExtensionWindowAdapter?

    var view: WKWebView? {
        if let tab { return tab.webView }
        return auxiliaryWebView
    }
    var tabID: UUID? { tab?.id }

    init(tab: Tab, state: BrowserState, owner: WebExtensionWindowAdapter? = nil) {
        self.tab = tab
        self.state = state
        self.owner = owner
        super.init()
    }

    init(webView: WKWebView, owner: WebExtensionWindowAdapter? = nil) {
        auxiliaryWebView = webView
        self.owner = owner
        super.init()
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard let view, view.configuration.webExtensionController === context.webExtensionController else { return nil }
        return view
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        owner?.tabProvider().firstIndex(where: { $0 === self }) ?? NSNotFound
    }
    func title(for context: WKWebExtensionContext) -> String? { tab?.displayTitle ?? view?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.url ?? view?.url }
    func pendingURL(for context: WKWebExtensionContext) -> URL? { tab?.pendingURL }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.isLoading ?? view?.isLoading ?? false) }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { tab?.isPlayingAudio ?? false }
    func isMuted(for context: WKWebExtensionContext) -> Bool { tab?.isMuted ?? false }
    func isPinned(for context: WKWebExtensionContext) -> Bool {
        guard let tab, let state else { return false }
        return state.space(of: tab)?.isPinned(tab) ?? false
    }
    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool { tab?.isReaderable ?? false }
    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool { tab?.isReaderOpen ?? false }
    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab else { return owner?.activeTab(for: context) === self }
        return owner?.model?.isShowing(tab) ?? false
    }
    func size(for context: WKWebExtensionContext) -> CGSize { view?.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(view?.pageZoom ?? 1) }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tab, let state, state.space(of: tab) != nil else {
            completionHandler(extensionAdapterError("This tab is no longer open.")); return
        }
        guard tab.favoriteID == nil else {
            completionHandler(extensionAdapterError("Favorites cannot be pinned as regular tabs.")); return
        }
        if pinned != isPinned(for: context) { state.togglePin(tab) }
        completionHandler(nil)
    }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tab, let state, state.space(of: tab) != nil else {
            completionHandler(extensionAdapterError("Audio controls are unavailable for this window.")); return
        }
        tab.isMuted = muted
        state.media.applyMute(to: tab)
        state.scheduleSave()
        completionHandler(nil)
    }

    func setReaderModeActive(_ active: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tab, let state, state.space(of: tab) != nil else {
            completionHandler(extensionAdapterError("Reader view is unavailable for this tab.")); return
        }
        if tab.isReaderOpen == active { completionHandler(nil); return }
        state.lifecycle.ensureLive(tab)
        guard let view else { completionHandler(extensionAdapterError("The tab could not be loaded.")); return }
        Task { @MainActor in
            let result = await ReaderMode.toggle(in: view, fontSize: state.settings.readerFontSize)
            tab.isReaderOpen = result
            completionHandler(result == active ? nil : extensionAdapterError("Reader view could not be changed for this page."))
        }
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard zoomFactor.isFinite, zoomFactor >= 0 else {
            completionHandler(extensionAdapterError("Zoom must be a finite positive number, or zero to reset it.")); return
        }
        guard let view = liveView() else { completionHandler(extensionAdapterError("This tab is no longer open.")); return }
        view.pageZoom = CGFloat(zoomFactor == 0 ? 1 : zoomFactor)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        let scheme = url.scheme?.lowercased() ?? ""
        let website = scheme == "http" || scheme == "https" || url.absoluteString == "about:blank"
        let extensionPage = tab == nil && view?.configuration.webExtensionController === context.webExtensionController
            && scheme == context.baseURL.scheme && url.host == context.baseURL.host
        guard website || extensionPage else {
            completionHandler(extensionAdapterError("Extensions can navigate to websites and their own pages, not local files or application URLs."))
            return
        }
        if let tab, let state, state.space(of: tab) != nil {
            state.lifecycle.load(url, fallbacks: [], in: tab)
            state.scheduleSave()
            completionHandler(nil)
        } else if tab == nil, let view {
            view.load(URLRequest(url: url))
            completionHandler(nil)
        } else { completionHandler(extensionAdapterError("This tab is no longer open.")) }
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let view = liveView() else { completionHandler(extensionAdapterError("This tab is no longer open.")); return }
        if fromOrigin { view.reloadFromOrigin() } else { view.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let view = liveView(), view.canGoBack else {
            completionHandler(extensionAdapterError("There is no previous page in this tab.")); return
        }
        view.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let view = liveView(), view.canGoForward else {
            completionHandler(extensionAdapterError("There is no next page in this tab.")); return
        }
        view.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let tab, let state, state.space(of: tab) != nil {
            guard let window = owner?.model ?? state.window(showing: tab)
                ?? state.windows.first(where: { $0.space.contains(tab) }) else {
                completionHandler(extensionAdapterError("The tab has no browser window.")); return
            }
            state.select(tab, in: window)
        }
        guard let window = view?.window ?? owner?.resolvedNativeWindow else {
            completionHandler(extensionAdapterError("The tab's window is no longer open.")); return
        }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        if let view { window.makeFirstResponder(view) }
        NSApp.activate()
        completionHandler(nil)
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if selected { activate(for: context, completionHandler: completionHandler) }
        else if !isSelected(for: context) { completionHandler(nil) }
        else { completionHandler(extensionAdapterError("A visible tab must remain selected in its pane.")) }
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let tab, let state, state.space(of: tab) != nil {
            state.close(tab)
            completionHandler(nil)
        } else if tab == nil, let view {
            if let delegate = view.uiDelegate, delegate.responds(to: #selector(WKUIDelegate.webViewDidClose(_:))) {
                delegate.webViewDidClose?(view)
                completionHandler(nil)
            } else if let window = view.window ?? owner?.resolvedNativeWindow {
                window.performClose(nil)
                completionHandler(nil)
            } else { completionHandler(extensionAdapterError("The tab's window is no longer open.")) }
        } else { completionHandler(extensionAdapterError("This tab is no longer open.")) }
    }

    private func liveView() -> WKWebView? {
        if let tab {
            guard let state, state.space(of: tab) != nil else { return nil }
            state.lifecycle.ensureLive(tab)
            return tab.webView
        }
        return auxiliaryWebView
    }
}

/// A browser window, or an auxiliary native window. Providers are supplied by
/// the owning profile so extensions only see tabs in that profile.
@MainActor
final class WebExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    weak var model: WindowState?
    weak var state: BrowserState?
    weak var nativeWindow: NSWindow?
    var privateBrowsing = false
    var tabProvider: () -> [WebExtensionTabAdapter] = { [] }
    var activeTabProvider: (() -> WebExtensionTabAdapter?)?

    init(model: WindowState? = nil, state: BrowserState? = nil, nativeWindow: NSWindow? = nil) {
        self.model = model
        self.state = state
        self.nativeWindow = nativeWindow
        super.init()
    }

    var resolvedNativeWindow: NSWindow? {
        nativeWindow ?? model?.activeTab?.webView?.window
            ?? model?.visibleTabs.compactMap { $0.webView?.window }.first
            ?? tabProvider().compactMap { $0.view?.window }.first
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabProvider() }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        if let activeTabProvider { return activeTabProvider() }
        if let tab = model?.activeTab { return tabProvider().first { $0.tab === tab } }
        return tabProvider().last
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { model == nil ? .popup : .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        privateBrowsing || tabProvider().first?.view?.configuration.websiteDataStore.isPersistent == false
    }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        resolvedNativeWindow?.screen?.frame ?? NSScreen.main?.frame ?? .zero
    }
    func frame(for context: WKWebExtensionContext) -> CGRect { resolvedNativeWindow?.frame ?? model?.currentFrame ?? .zero }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = resolvedNativeWindow else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        return window.isZoomed ? .maximized : .normal
    }

    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = resolvedNativeWindow else { completionHandler(extensionAdapterError("This window is no longer open.")); return }
        switch state {
        case .fullscreen:
            window.deminiaturize(nil)
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case .minimized:
            window.miniaturize(nil)
        case .maximized:
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            window.deminiaturize(nil)
            if !window.isZoomed { window.zoom(nil) }
        case .normal:
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            window.deminiaturize(nil)
            if window.isZoomed { window.zoom(nil) }
        @unknown default:
            completionHandler(extensionAdapterError("This window state is unsupported.")); return
        }
        completionHandler(nil)
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = resolvedNativeWindow else { completionHandler(extensionAdapterError("This window is no longer open.")); return }
        guard [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite), frame.width > 0, frame.height > 0 else {
            completionHandler(extensionAdapterError("Window dimensions must be finite and positive.")); return
        }
        window.setFrame(frame, display: true)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = resolvedNativeWindow else { completionHandler(extensionAdapterError("This window is no longer open.")); return }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = resolvedNativeWindow else { completionHandler(extensionAdapterError("This window is no longer open.")); return }
        window.performClose(nil)
        completionHandler(nil)
    }
}
