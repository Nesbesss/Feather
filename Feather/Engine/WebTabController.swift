import AppKit
import WebKit

/// WebKit delegate for one live tab: mirrors web view state into the `Tab`
/// model and handles links, popups, failures, dialogs, and downloads.
final class WebTabController: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var tab: Tab?
    unowned let state: BrowserState
    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    /// Set once the page has drawn, so a placeholder snapshot can be removed.
    private(set) var hasPainted = false
    var onFirstPaint: (() -> Void)?
    /// The last URL Clean Links rewrote, so a site that redirects straight back to it isn't fought forever.
    private var lastCleaned: (url: URL, at: Date)?
    private let navigationProtection: WebNavigationProtection

    init(tab: Tab, webView: WKWebView, state: BrowserState) {
        self.tab = tab
        self.webView = webView
        self.state = state
        navigationProtection = state.lifecycle.factory.navigationProtection()
        super.init()
        webView.setAccessibilityIdentifier("feather.web-content.\(tab.id.uuidString)")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeWebView()
    }

    func invalidate() {
        navigationProtection.invalidate()
        observations.forEach { $0.invalidate() }
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        onFirstPaint = nil
    }

    private func observeWebView() {
        func watch<Value>(_ keyPath: KeyPath<WKWebView, Value>, _ apply: @escaping (Tab, WKWebView) -> Void) {
            observations.append(webView.observe(keyPath, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let tab = self?.tab else { return }
                    apply(tab, webView)
                }
            })
        }
        watch(\.title) { [weak self] tab, webView in
            if let title = webView.title, !title.isEmpty { tab.title = title }
            self?.state.lifecycle.factory.extensions.didChange(tab, properties: .title)
        }
        watch(\.url) { [weak self] tab, webView in
            // Keep a recent catch through YouTube's same-document transitions.
            // True main navigations have a separate document epoch.
            self?.state.lifecycle.factory.adCatch.urlDidChange(in: webView, from: tab.url)
            if let url = webView.url, url.absoluteString != "about:blank" || tab.url == nil {
                tab.url = url
                self?.state.scheduleSave()
                self?.state.lifecycle.factory.extensions.didChange(tab, properties: .URL)
            }
        }
        watch(\.isLoading) { [weak self] tab, webView in
            tab.isLoading = webView.isLoading
            self?.state.lifecycle.factory.extensions.didChange(tab, properties: .loading)
        }
        watch(\.estimatedProgress) { tab, webView in tab.progress = webView.estimatedProgress }
        watch(\.canGoBack) { tab, webView in tab.canGoBack = webView.canGoBack }
        watch(\.canGoForward) { tab, webView in tab.canGoForward = webView.canGoForward }
        watch(\.hasOnlySecureContent) { tab, webView in tab.isSecure = webView.hasOnlySecureContent }
        watch(\.themeColor) { tab, webView in tab.themeColor = webView.themeColor }
    }

    private func markPainted() {
        guard !hasPainted else { return }
        hasPainted = true
        onFirstPaint?()
        onFirstPaint = nil
        tab?.snapshotJPEG = nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if action.shouldPerformDownload { return (.download, preferences) }
        guard let url = action.request.url else { return (.allow, preferences) }
        let scheme = url.scheme?.lowercased() ?? ""

        if !["http", "https", "about", "file", "blob", "data"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return (.cancel, preferences)
        }

        // ⇧-click: preview the link in a floating panel.
        let modifiers = action.modifierFlags.intersection([.shift, .command, .option, .control])
        if action.navigationType == .linkActivated, modifiers == .shift, action.buttonNumber != 2,
           let tab, let window = webView.window {
            PeekWindowController.show(state.settings.cleanLinks ? LinkCleaner.clean(url) : url, from: tab, in: window, state: state)
            return (.cancel, preferences)
        }

        let wantsNewTab = action.navigationType == .linkActivated
            && (action.modifierFlags.contains(.command) || action.buttonNumber == 2)
        if wantsNewTab, let tab, let window = state.window(showing: tab) ?? state.keyWindow {
            let foreground = action.modifierFlags.contains(.shift)
            state.openTab(state.settings.cleanLinks ? LinkCleaner.clean(url) : url, in: window, background: !foreground, after: tab)
            return (.cancel, preferences)
        }

        // Tracking parameters are dropped before the page loads, so the site never sees them.
        if state.settings.cleanLinks, action.targetFrame?.isMainFrame ?? true, (action.request.httpMethod ?? "GET") == "GET",
           action.navigationType == .linkActivated || action.navigationType == .other {
            let cleaned = LinkCleaner.clean(url)
            let justCleaned = lastCleaned.map { $0.url == url && Date.now.timeIntervalSince($0.at) < 10 } ?? false
            if cleaned != url, !justCleaned {
                lastCleaned = (url, .now)
                webView.load(URLRequest(url: cleaned))
                return (.cancel, preferences)
            }
        }

        guard await navigationProtection.prepare(for: action, in: webView, delegate: self) else { return (.cancel, preferences) }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if !response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        state.downloads.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        state.downloads.track(download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.documentID = UUID()
        tab?.hasUnsavedInput = false  // a new document has no typed input yet
        tab?.declinedCookies = nil
        tab?.media = nil
        tab?.mediaFrame = nil
        tab?.isReaderable = false
        tab?.isReaderOpen = false
        // Give the first frame a moment to draw before dropping the placeholder.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.markPainted() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        markPainted()
        navigationProtection.didFinish(in: webView, delegate: self)
        guard let tab else { return }
        tab.fallbackURLs = []
        if let url = webView.url, let space = state.space(of: tab) {
            state.history?.record(url, title: webView.title ?? "", space: space.id)
        }
        Task { await Favicons.shared.update(tab, from: webView) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        // Cancelled loads and policy changes (for example, a download) are not failures.
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && error.code == 102) { return }
        guard let tab else { return }
        if !tab.fallbackURLs.isEmpty {
            webView.load(URLRequest(url: tab.fallbackURLs.removeFirst()))
            return
        }
        let failingURL = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? tab.url
        webView.loadHTMLString(Self.errorPage(error, url: failingURL), baseURL: failingURL)
        markPainted()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab else { return }
        if state.window(showing: tab) != nil {
            webView.reload()
        } else {
            state.lifecycle.discard(tab, keepingState: true)
        }
    }

    // MARK: WKUIDelegate

    /// `window.open` and `target=_blank`: a sized `window.open` (a sign-in popup)
    /// gets a small window; anything else a new tab next to this one. Both use
    /// WebKit's configuration so the opener relationship survives.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let tab, let window = state.window(showing: tab) ?? state.keyWindow else { return nil }
        let background = action.modifierFlags.contains(.command)
        if !background, windowFeatures.width != nil || windowFeatures.height != nil, let space = state.space(of: tab) {
            return PopupWindowController(configuration: configuration, features: windowFeatures, opener: tab,
                                         space: space, parent: webView.window, state: state).webView
        }
        let newTab = state.openTab(action.request.url, in: window, background: background, after: tab,
                                   configuration: configuration)
        return newTab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab { state.close(tab) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await present(message: message, frame: frame, buttons: ["OK"])
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await present(message: message, frame: frame, buttons: ["OK", "Cancel"]) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let response = await present(message: prompt, frame: frame, buttons: ["OK", "Cancel"], accessory: field)
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let window = webView.window else { return panel.runModal() == .OK ? panel.urls : nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    private func present(message: String, frame: WKFrameInfo, buttons: [String],
                         accessory: NSView? = nil) async -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.accessoryView = accessory
        guard let window = webView.window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }

    private static func errorPage(_ error: NSError, url: URL?) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let address = escape(url?.absoluteString ?? "")
        return """
            <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>Can't open page</title>
            <style>body{font:15px -apple-system,sans-serif;display:grid;place-items:center;height:90vh;margin:0;color:#888}
            main{max-width:440px;text-align:center}h1{font-size:22px;color:CanvasText}a{color:#0a84ff}</style>
            <main><h1>Can't open this page</h1><p>\(escape(error.localizedDescription))</p>
            <p><a href="\(address)">Try again</a></p></main>
            """
    }
}
