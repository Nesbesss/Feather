import AppKit
import WebKit

/// A small window for a sized `window.open`, such as "Sign in with Google".
/// It uses WebKit's configuration, so `window.opener` and the OAuth hand-back
/// work, and it closes itself when the page calls `window.close()`. The header
/// always shows which site is asking.
final class PopupWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let spaceID: UUID
    private unowned let state: BrowserState
    private(set) weak var opener: Tab?
    private let header = PopupHeader()
    private var observations: [NSKeyValueObservation] = []
    private var adopted = false
    private let navigationProtection: WebNavigationProtection

    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, opener: Tab, space: Space,
         parent: NSWindow?, state: BrowserState) {
        self.state = state
        spaceID = space.id
        self.opener = opener
        navigationProtection = state.lifecycle.factory.navigationProtection()
        webView = state.lifecycle.factory.makeWebView(for: space, configuration: configuration)

        let screen = parent?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(max(features.width?.doubleValue ?? 500, 360), min(1000, screen.width - 40))
        let height = min(max(features.height?.doubleValue ?? 600, 360), min(900, screen.height - 80)) + PopupHeader.height
        let center = parent.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY + 30) } ?? NSPoint(x: screen.midX, y: screen.midY)
        var frame = NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        frame.origin.x = min(max(frame.minX, screen.minX + 20), screen.maxX - width - 20)
        frame.origin.y = min(max(frame.minY, screen.minY + 20), screen.maxY - height - 20)

        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 320)
        window.title = "Sign in"
        super.init(window: window)
        window.delegate = self

        let container = NSView()
        [header, webView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: PopupHeader.height),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        header.onOpenAsTab = { [weak self] in self?.openAsTab() }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateHeader() }
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateHeader() }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    if let title = webView.title, !title.isEmpty { self?.window?.title = title }
                }
            },
        ]
        state.popups.append(self)
        showWindow(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func updateHeader() {
        let url = webView.url
        let host = url?.host() ?? ""
        header.update(host: host.isEmpty ? (url?.absoluteString ?? "") : host,
                      secure: url?.scheme == "https" && webView.hasOnlySecureContent)
    }

    /// Moves the page into a regular tab next to its opener.
    private func openAsTab() {
        guard let target = state.auxiliaryTabTarget(spaceID: spaceID, opener: opener) else {
            close()
            return
        }
        adopted = true
        detach()
        webView.removeFromSuperview()
        state.adopt(webView, in: target.window, after: target.anchor)
        close()
    }

    private func detach() {
        navigationProtection.invalidate()
        observations.forEach { $0.invalidate() }
        observations = []
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func windowWillClose(_ notification: Notification) {
        if !adopted {
            state.lifecycle.factory.extensions.untrack(webView)
            detach()
            webView.stopLoading()
        }
        state.popups.removeAll { $0 === self }
    }

    // MARK: WebKit

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let allowed = await navigationProtection.prepare(for: action, in: webView, delegate: self)
        return (allowed ? .allow : .cancel, preferences)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationProtection.didFinish(in: webView, delegate: self)
    }

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        close()
    }

    /// Windows opened from the popup become tabs in its creation space.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let target = state.auxiliaryTabTarget(spaceID: spaceID, opener: opener) else {
            close()
            return nil
        }
        return state.openTab(action.request.url, in: target.window, after: target.anchor, configuration: configuration).webView
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        _ = await alert.beginSheetModal(for: window)
    }
}

/// Lock (or warning) + host, and "Open as Tab".
private final class PopupHeader: NSView {
    static let height: CGFloat = 30
    var onOpenAsTab: (() -> Void)?
    private let icon = NSImageView()
    private let hostLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        hostLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        hostLabel.lineBreakMode = .byTruncatingHead
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        let button = NSButton(title: "Open as Tab", target: self, action: #selector(openAsTab))
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        separator.boxType = .separator
        let stack = NSStackView(views: [icon, hostLabel, NSView(), button])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        [stack, separator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(host: String, secure: Bool) {
        hostLabel.stringValue = host
        icon.image = NSImage(systemSymbolName: secure ? "lock.fill" : "exclamationmark.triangle.fill",
                             accessibilityDescription: secure ? "Secure" : "Not secure")
        icon.contentTintColor = secure ? .secondaryLabelColor : .systemOrange
        toolTip = secure ? host : "\(host) — not secure"
    }

    @objc private func openAsTab() { onOpenAsTab?() }
}
