import AppKit
import SwiftUI
import WebKit

/// One rounded content card. It hosts the tab's web view, a thin progress
/// line, and, while a sleeping tab wakes, the snapshot taken when it slept.
final class WebPaneView: NSView {
    private(set) var tab: Tab?
    private weak var hostedWebView: WKWebView?
    private let snapshotView = NSImageView()
    private let progressLayer = CALayer()
    private let linkPill = LinkPill()
    private var loop: ObservationLoop?
    var onFocus: (() -> Void)?

    var cornerRadius: CGFloat = 10 {
        didSet { layer?.cornerRadius = cornerRadius }
    }
    /// Liquid Glass prototype: the hovered-link pill turns to glass.
    var glass = false {
        didSet { linkPill.glass = glass }
    }

    var isFocusedPane = false {
        didSet { updateBorder() }
    }
    /// Only split view marks the focused pane.
    var showsFocusRing = false {
        didSet { updateBorder() }
    }

    private func updateBorder() {
        let ring = showsFocusRing && isFocusedPane
        layer?.borderWidth = ring ? 1.5 : 0.5
        layer?.borderColor = (ring ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        snapshotView.imageScaling = .scaleProportionallyUpOrDown
        snapshotView.imageAlignment = .alignTop
        snapshotView.isHidden = true
        snapshotView.autoresizingMask = [.width, .height]
        addSubview(snapshotView)

        linkPill.isHidden = true
        addSubview(linkPill)

        progressLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        progressLayer.zPosition = 10
        layer?.addSublayer(progressLayer)

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ tab: Tab?) {
        guard tab !== self.tab || loop == nil else { return }
        self.tab = tab
        loop?.cancel()
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    override func layout() {
        super.layout()
        hostedWebView?.frame = bounds
        snapshotView.frame = bounds
        layoutProgress()
        layoutLinkPill()
    }

    private func layoutLinkPill() {
        let size = linkPill.fittingSize
        let width = min(size.width, bounds.width * 0.6)
        var frame = NSRect(x: 8, y: isFlipped ? bounds.height - size.height - 8 : 8, width: width, height: size.height)
        // Like Safari's status bar, it moves to the other corner when the pointer is under it.
        if let window, frame.insetBy(dx: -24, dy: -24).contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            frame.origin.x = bounds.width - width - 8
        }
        linkPill.frame = frame
    }

    @objc private func clicked() {
        onFocus?()
    }

    private func render() {
        let webView = tab?.webView
        if hostedWebView !== webView {
            // A web view moved to another window's pane is no longer ours to remove.
            if hostedWebView?.superview === self { hostedWebView?.removeFromSuperview() }
            hostedWebView = webView
            if let webView {
                webView.frame = bounds
                webView.autoresizingMask = [.width, .height]
                addSubview(webView, positioned: .below, relativeTo: snapshotView)
                showSnapshotWhileWaking()
            } else {
                snapshotView.isHidden = true
                snapshotView.image = nil
            }
        }
        _ = tab?.isLoading
        _ = tab?.progress
        layoutProgress()
        let link = tab?.hoveredLink
        linkPill.isHidden = link == nil
        if let link {
            linkPill.text = link.absoluteString.removingPercentEncoding ?? link.absoluteString
            layoutLinkPill()
        }
    }

    private func showSnapshotWhileWaking() {
        guard let tab, let controller = tab.controller, !controller.hasPainted,
              let jpeg = tab.snapshotJPEG, let image = NSImage(data: jpeg) else {
            snapshotView.isHidden = true
            snapshotView.image = nil
            return
        }
        snapshotView.image = image
        snapshotView.isHidden = false
        controller.onFirstPaint = { [weak self, weak tab, weak controller] in
            guard let self, let tab, let controller,
                  self.tab === tab, tab.controller === controller else { return }
            self.snapshotView.isHidden = true
            self.snapshotView.image = nil
        }
    }

    private func layoutProgress() {
        CATransaction.begin()
        CATransaction.setDisableActions(!(tab?.isLoading ?? false))
        let loading = tab?.isLoading ?? false
        let fraction = loading ? max(0.05, tab?.progress ?? 0) : 0
        progressLayer.frame = CGRect(x: 0, y: isFlipped ? 0 : bounds.height - 2, width: bounds.width * fraction, height: 2)
        progressLayer.opacity = loading ? 1 : 0
        CATransaction.commit()
    }
}

/// Lays out one card, or two cards with a draggable gap between them.
final class ContentAreaView: NSView {
    let primaryPane = WebPaneView()
    let secondaryPane = WebPaneView()
    private let divider = SplitDividerView()
    private let emptyView = NSHostingView(rootView: StartPageView())
    private let primaryShadow = CardShadowView()
    private let secondaryShadow = CardShadowView()
    private var ratio = 0.5
    private var isSplit = false
    var onFocusSecondary: ((Bool) -> Void)?
    var onRatioChange: ((Double) -> Void)?
    var cornerRadius: CGFloat = 10 {
        didSet {
            guard cornerRadius != oldValue else { return }
            [primaryPane, secondaryPane].forEach { $0.cornerRadius = cornerRadius }
            [primaryShadow, secondaryShadow].forEach { $0.cornerRadius = cornerRadius }
        }
    }
    var glass = false {
        didSet {
            guard glass != oldValue else { return }
            [primaryPane, secondaryPane].forEach { $0.glass = glass }
            [primaryShadow, secondaryShadow].forEach { $0.strong = glass }
            emptyView.rootView = StartPageView(glass: glass)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [primaryShadow, secondaryShadow, primaryPane, secondaryPane, divider, emptyView].forEach(addSubview)
        primaryPane.onFocus = { [weak self] in self?.onFocusSecondary?(false) }
        secondaryPane.onFocus = { [weak self] in self?.onFocusSecondary?(true) }
        divider.onDrag = { [weak self] x in
            guard let self, self.bounds.width > 0 else { return }
            let ratio = min(0.8, max(0.2, Double(x / self.bounds.width)))
            self.ratio = ratio
            self.needsLayout = true
            self.onRatioChange?(ratio)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(primary: Tab?, secondary: Tab?, ratio: Double, focusSecondary: Bool) {
        isSplit = secondary != nil
        self.ratio = ratio
        primaryPane.show(primary)
        secondaryPane.show(secondary)
        secondaryPane.isHidden = !isSplit
        secondaryShadow.isHidden = !isSplit
        divider.isHidden = !isSplit
        primaryPane.isHidden = primary == nil
        primaryShadow.isHidden = primary == nil
        emptyView.isHidden = primary != nil
        for (pane, focused) in [(primaryPane, !focusSecondary), (secondaryPane, focusSecondary)] {
            pane.showsFocusRing = isSplit
            pane.isFocusedPane = focused
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 8
        if isSplit {
            let leftWidth = ((bounds.width - gap) * ratio).rounded()
            primaryPane.frame = NSRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
            divider.frame = NSRect(x: leftWidth, y: 0, width: gap, height: bounds.height)
            secondaryPane.frame = NSRect(x: leftWidth + gap, y: 0, width: bounds.width - leftWidth - gap, height: bounds.height)
        } else {
            primaryPane.frame = bounds
        }
        primaryShadow.frame = primaryPane.frame
        secondaryShadow.frame = secondaryPane.frame
        // Let SwiftUI reflow into the content area when the sidebar is wide or
        // the browser is at its minimum size, instead of clipping a fixed card.
        let fitting = emptyView.fittingSize
        let size = NSSize(width: min(fitting.width, bounds.width), height: min(fitting.height, bounds.height))
        emptyView.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height)
    }
}

/// The gap between split panes; dragging it resizes them.
final class SplitDividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }
}

/// A soft shadow under a content card (the card itself clips to its rounded corners).
final class CardShadowView: NSView {
    var cornerRadius: CGFloat = 10 {
        didSet { needsLayout = true }
    }
    /// Deeper shadow for the Liquid Glass prototype, where cards float over a see-through window.
    var strong = false {
        didSet {
            layer?.shadowOpacity = strong ? 0.22 : 0.12
            layer?.shadowRadius = strong ? 14 : 5
            layer?.shadowOffset = CGSize(width: 0, height: strong ? -4 : -1)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }
}

/// The hovered link's URL, at the bottom left of a card.
final class LinkPill: NSView {
    private let label = NSTextField(labelWithString: "")
    private var glassView: NSGlassEffectView?

    var glass = false {
        didSet {
            guard glass != oldValue else { return }
            if glass {
                let view = NSGlassEffectView()
                addSubview(view, positioned: .below, relativeTo: label)
                glassView = view
            } else {
                glassView?.removeFromSuperview()
                glassView = nil
            }
            needsLayout = true
            needsDisplay = true
        }
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.backgroundColor = glass ? NSColor.clear.cgColor : NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.borderColor = glass ? NSColor.clear.cgColor : NSColor.separatorColor.cgColor
    }

    override var fittingSize: NSSize {
        let size = label.fittingSize
        return NSSize(width: size.width + 16, height: size.height + 6)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 8, dy: 3)
        glassView?.frame = bounds
        glassView?.cornerRadius = bounds.height / 2
    }
}
