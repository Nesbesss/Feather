import AppKit
import WebKit

/// ⇧-click a link to preview it in a floating panel over the window, without
/// opening a tab. ⌘↩ (or "Open as Tab") keeps it as a tab; Esc, the close
/// button, or clicking back in the window dismisses it and frees its web process.
final class PeekWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    /// One peek at a time; it retains itself while shown.
    private static var current: PeekWindowController?

    private let panel: PeekPanel
    private let webView: WKWebView
    let spaceID: UUID
    private unowned let state: BrowserState
    private weak var opener: Tab?
    private weak var parent: NSWindow?
    private let header = PeekHeader()
    private var observations: [NSKeyValueObservation] = []
    private var adopted = false
    private let navigationProtection: WebNavigationProtection

    static func show(_ url: URL, from opener: Tab, in parent: NSWindow, state: BrowserState) {
        current?.close()
        guard let space = state.space(of: opener) else { return }
        let peek = PeekWindowController(url: url, opener: opener, space: space, parent: parent, state: state)
        current = peek
        peek.show()
    }

    static func dismiss(in parent: NSWindow) {
        guard let peek = current, peek.parent === parent else { return }
        peek.close()
    }

    static func dismiss(inSpace spaceID: UUID) {
        guard let peek = current, peek.spaceID == spaceID else { return }
        peek.close()
    }

    private init(url: URL, opener: Tab, space: Space, parent: NSWindow, state: BrowserState) {
        self.state = state
        spaceID = space.id
        self.opener = opener
        self.parent = parent
        navigationProtection = state.lifecycle.factory.navigationProtection()
        webView = state.lifecycle.factory.makeWebView(for: space)
        let content = parent.contentLayoutRect
        let frame = parent.convertToScreen(content).insetBy(dx: max(40, content.width * 0.1), dy: max(30, content.height * 0.06))
        panel = PeekPanel(contentRect: frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.onClose = { [weak self] in self?.close() }
        panel.onOpenAsTab = { [weak self] in self?.openAsTab() }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        [header, webView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        header.onOpenAsTab = { [weak self] in self?.openAsTab() }
        header.onClose = { [weak self] in self?.close() }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.header.update(url: webView.url, title: webView.title) }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.header.update(url: webView.url, title: webView.title) }
            },
        ]
        webView.load(URLRequest(url: url))
    }

    private func show() {
        guard let parent else { return }
        parent.addChildWindow(panel, ordered: .above)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard Self.current === self else { return }
        Self.current = nil
        navigationProtection.invalidate()
        observations.forEach { $0.invalidate() }
        observations = []
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if !adopted {
            state.lifecycle.factory.extensions.untrack(webView)
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func openAsTab() {
        guard let target = state.auxiliaryTabTarget(spaceID: spaceID, opener: opener) else {
            close()
            return
        }
        adopted = true
        webView.removeFromSuperview()
        let webView = self.webView
        close()
        state.adopt(webView, in: target.window, after: target.anchor)
    }

    /// Clicking back into the browser window dismisses the peek.
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !panel.isKeyWindow, !NSApp.windows.contains(where: { $0.isKeyWindow && $0.sheetParent === self.panel }) else { return }
            if NSApp.keyWindow === parent { close() }
        }
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

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let target = state.auxiliaryTabTarget(spaceID: spaceID, opener: opener) else {
            close()
            return nil
        }
        let tab = state.openTab(action.request.url, in: target.window, after: target.anchor, configuration: configuration)
        close()
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) { close() }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { close() }
}

private final class PeekPanel: NSPanel {
    var onClose: (() -> Void)?
    var onOpenAsTab: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, flags == .command, event.keyCode == 36 || event.keyCode == 76 {  // ⌘↩
            onOpenAsTab?()
            return true
        }
        if event.type == .keyDown, flags == .command, event.charactersIgnoringModifiers == "w" {
            onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Host and title, "Open as Tab", and close.
private final class PeekHeader: NSView {
    var onOpenAsTab: (() -> Void)?
    var onClose: (() -> Void)?
    private let hostLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        hostLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let open = NSButton(title: "Open as Tab  ⌘↩", target: self, action: #selector(openAsTab))
        open.bezelStyle = .accessoryBarAction
        open.controlSize = .small
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close preview")!,
                             target: self, action: #selector(closePeek))
        close.bezelStyle = .accessoryBarAction
        close.controlSize = .small
        close.toolTip = "Close (Esc)"
        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [hostLabel, titleLabel, NSView(), open, close])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 8)
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

    func update(url: URL?, title: String?) {
        hostLabel.stringValue = url?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        titleLabel.stringValue = title ?? ""
    }

    @objc private func openAsTab() { onOpenAsTab?() }
    @objc private func closePeek() { onClose?() }
}
