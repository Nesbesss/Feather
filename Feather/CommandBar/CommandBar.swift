import AppKit
import SwiftUI

enum CommandBarMode {
    /// Cmd-T: opens what you type in a new tab.
    case newTab
    /// Cmd-L or clicking the address pill: edits the current tab's address.
    case edit
}

struct Suggestion: Identifiable {
    enum Action {
        case go(String)
        case switchTo(Tab)
        case open(URL)
        case restoreArchived(UUID)
        case openFavorite(Favorite)
    }

    enum Icon {
        case symbol(String)
        case site(String)
        case tab(Tab)
    }

    let id = UUID()
    var title: String
    var subtitle: String
    var icon: Icon
    var action: Action
}

@Observable
final class CommandBarModel {
    /// What the user typed, without the inline completion.
    var text: String {
        didSet { refresh() }
    }
    /// The host the field completes `text` to, shown selected after the typed part.
    private(set) var completion: String?
    /// Off while the user deletes, so backspace isn't fighting the completion.
    @ObservationIgnored var allowsCompletion = true
    var selection = 0
    private(set) var suggestions: [Suggestion] = []
    let mode: CommandBarMode
    @ObservationIgnored unowned let state: BrowserState
    @ObservationIgnored let window: WindowState
    @ObservationIgnored var onDone: (() -> Void)?

    init(mode: CommandBarMode, state: BrowserState, window: WindowState) {
        self.mode = mode
        self.state = state
        self.window = window
        text = mode == .edit ? (window.activeTab?.url?.absoluteString ?? "") : ""
        refresh()
    }

    func move(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        selection = (selection + delta + suggestions.count) % suggestions.count
    }

    /// Tab or → at the end: take the completion as typed text.
    func acceptCompletion() -> Bool {
        guard let completion else { return false }
        allowsCompletion = false
        text = completion
        return true
    }

    func commit(_ index: Int) {
        guard suggestions.indices.contains(index) else { return }
        switch suggestions[index].action {
        case .go(let text):
            state.go(to: text, in: window, newTab: mode == .newTab)
        case .switchTo(let tab):
            state.select(tab, in: window)
        case .open(let url):
            state.go(to: url.absoluteString, in: window, newTab: mode == .newTab)
        case .restoreArchived(let id):
            state.restoreArchived(id, in: window.space, window: window)
        case .openFavorite(let favorite):
            state.open(favorite, in: window)
        }
        onDone?()
    }

    private func refresh() {
        selection = 0
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        completion = allowsCompletion && query == text ? completeHost(query) : nil
        var results: [Suggestion] = []
        if let completion {
            results.append(Suggestion(title: completion, subtitle: "Open", icon: .site(completion), action: .go(completion)))
        } else {
            switch URLInput.resolve(query) {
            case .url(let url, _)?:
                results.append(Suggestion(title: url.absoluteString, subtitle: "Open", icon: .symbol("arrow.up.right"),
                                          action: .go(query)))
            case .search?:
                results.append(Suggestion(title: query, subtitle: "Search \(state.settings.searchEngine.title)",
                                          icon: .symbol("magnifyingglass"), action: .go(query)))
            case nil:
                break
            }
        }

        let needle = query.lowercased()
        func matches(title: String, url: String?) -> Bool {
            needle.isEmpty || title.lowercased().contains(needle) || (url?.lowercased().contains(needle) ?? false)
        }
        let space = window.space
        let openTabs = space.allTabs.filter { !window.isShowing($0) && matches(title: $0.displayTitle, url: $0.url?.absoluteString) }
        let openURLs = Set(space.allTabs.compactMap { $0.url?.absoluteString })
        for tab in openTabs.sorted(by: { $0.lastActive > $1.lastActive }).prefix(needle.isEmpty ? 6 : 4) {
            results.append(Suggestion(title: tab.displayTitle, subtitle: "Switch to Tab", icon: .tab(tab), action: .switchTo(tab)))
        }
        if !needle.isEmpty {
            for favorite in state.favorites where space.tab(for: favorite) == nil && results.count < 6
            && matches(title: favorite.displayTitle, url: favorite.url.absoluteString) {
                results.append(Suggestion(title: favorite.displayTitle, subtitle: "Favorite", icon: .site(favorite.host),
                                          action: .openFavorite(favorite)))
            }
            var archivedURLs = Set<String>()
            for item in space.archived where results.count < 7 && matches(title: item.tab.title, url: item.tab.url) {
                guard let url = item.tab.url, !openURLs.contains(url), archivedURLs.insert(url).inserted else { continue }
                results.append(Suggestion(title: item.tab.title.isEmpty ? url : item.tab.title,
                                          subtitle: "Archived \(item.archivedAt.formatted(.relative(presentation: .named)))",
                                          icon: URL(string: url)?.host().map(Suggestion.Icon.site) ?? .symbol("archivebox"),
                                          action: .restoreArchived(item.tab.id)))
            }
            if let history = state.history {
                let skip = openURLs.union(archivedURLs)
                for entry in history.search(query, space: space.id, limit: 6)
                where !skip.contains(entry.url.absoluteString) && results.count < 9 {
                    let host = entry.url.host()
                    results.append(Suggestion(title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                                              subtitle: host ?? entry.url.absoluteString,
                                              icon: host.map(Suggestion.Icon.site) ?? .symbol("clock"), action: .open(entry.url)))
                }
            }
        }
        suggestions = results
    }

    /// History hosts by visits, plus a bonus for sites open in this space.
    private func completeHost(_ typed: String) -> String? {
        guard !typed.isEmpty, !typed.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" }) else { return nil }
        var candidates = state.history?.hosts(withPrefix: typed, space: window.space.id) ?? []
        for tab in window.space.allTabs {
            if let host = tab.url?.host() { candidates.append(Autocomplete.Candidate(host: host, score: 3)) }
        }
        return Autocomplete.completion(for: typed, candidates: candidates)
    }
}

struct CommandBarView: View {
    @Bindable var model: CommandBarModel
    let close: () -> Void
    var width: CGFloat = 620

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                CommandField(model: model, close: close)
                    .frame(height: 24)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            if !model.suggestions.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        SuggestionRow(suggestion: suggestion, selected: index == model.selection)
                            .contentShape(Rectangle())
                            .onTapGesture { model.commit(index) }
                            .onHover { if $0 { model.selection = index } }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(suggestion.title)
                            .accessibilityValue(suggestion.subtitle)
                            .accessibilityIdentifier("feather.command.suggestion.\(index)")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAddTraits(index == model.selection ? .isSelected : [])
                            .accessibilityAction { model.commit(index) }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: width)
        .featherPanel(RoundedRectangle(cornerRadius: model.state.settings.glassInterface ? 22 : 14, style: .continuous),
                      glass: model.state.settings.glassInterface)
    }
}

/// The command bar's text field: an `NSTextField`, so the inline completion can
/// sit selected after the caret ("yo|utube.com") and arrow keys drive the list.
private struct CommandField: NSViewRepresentable {
    let model: CommandBarModel
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, close: close) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: model.text)
        field.placeholderString = "Search or enter address"
        field.setAccessibilityLabel("Search or enter address")
        field.setAccessibilityIdentifier("feather.command.address")
        field.setAccessibilityHelp("Type an address or search. Use arrow keys to choose a suggestion and Return to open it.")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        context.coordinator.typed = model.text
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {}

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: CommandBarModel
        let close: () -> Void
        /// The typed text as of the last edit, to tell typing from deleting.
        var typed = ""

        init(model: CommandBarModel, close: @escaping () -> Void) {
            self.model = model
            self.close = close
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let text = field.stringValue
            model.allowsCompletion = text.count > typed.count && text.lowercased().hasPrefix(typed.lowercased())
            typed = text
            model.text = text
            showCompletion(in: field)
        }

        private func showCompletion(in field: NSTextField) {
            guard let completion = model.completion, completion.count > typed.count,
                  completion.lowercased().hasPrefix(typed.lowercased()) else { return }
            let suffix = String(completion.dropFirst(typed.count))
            field.stringValue = typed + suffix
            field.currentEditor()?.selectedRange = NSRange(location: (typed as NSString).length,
                                                           length: (suffix as NSString).length)
        }

        private func accept(in field: NSTextField) -> Bool {
            guard model.acceptCompletion() else { return false }
            typed = model.text
            field.stringValue = typed
            field.currentEditor()?.selectedRange = NSRange(location: (typed as NSString).length, length: 0)
            return true
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                model.move(-1)
            case #selector(NSResponder.moveDown(_:)):
                model.move(1)
            case #selector(NSResponder.insertTab(_:)):
                _ = accept(in: field)
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
                return accept(in: field)
            case #selector(NSResponder.insertNewline(_:)):
                model.commit(model.selection)
            case #selector(NSResponder.cancelOperation(_:)):
                close()
            default:
                return false
            }
            return true
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: Suggestion
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch suggestion.icon {
                case .symbol(let name):
                    Image(systemName: name).foregroundStyle(selected ? .white : .secondary)
                case .site(let host):
                    FaviconImage(host: host, size: 16)
                case .tab(let tab):
                    Favicon(tab: tab, size: 16)
                }
            }
            .frame(width: 18)
            Text(suggestion.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            Text(suggestion.subtitle).lineLimit(1).foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
        }
        .font(.system(size: 13))
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor : .clear))
    }
}

/// Floating, borderless panel holding the command bar over the browser window.
final class CommandBarController: NSObject, NSWindowDelegate {
    private let panel: CommandBarPanel
    private let model: CommandBarModel
    private weak var parent: NSWindow?
    private var topY: CGFloat = 0
    private var centerX: CGFloat = 0
    private static let width: CGFloat = 620
    var onClose: (() -> Void)?
    var onCommit: (() -> Void)?
    var onEmbeddedLayout: (() -> Void)?
    private var embeddedHost: NSHostingView<CommandBarView>?
    private weak var embeddedParent: NSView?
    private var embeddedContentFrame = NSRect.zero
    private var embeddedLoop: ObservationLoop?
    var embeddedFrame: NSRect? { embeddedHost?.frame }

    init(mode: CommandBarMode, state: BrowserState, window: WindowState) {
        model = CommandBarModel(mode: mode, state: state, window: window)
        panel = CommandBarPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 54),
                                styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.title = mode == .newTab ? "New Tab" : "Open Location"
        panel.setAccessibilityIdentifier("feather.command-bar")
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        let hosting = NSHostingController(rootView: CommandBarView(model: model, close: { [weak self] in self?.close() }))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        model.onDone = { [weak self] in
            self?.onCommit?()
            self?.close()
        }
        panel.onCancel = { [weak self] in self?.close() }
    }

    func show(over window: NSWindow, contentFrame: NSRect) {
        parent = window
        let content = window.convertToScreen(contentFrame)
        topY = content.maxY - content.height * 0.18
        centerX = content.midX
        // The SwiftUI content sizes the panel after this, so position from the known width.
        panel.setFrame(NSRect(x: centerX - Self.width / 2, y: topY - 54, width: Self.width, height: 54), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard panel.isVisible || embeddedHost != nil else { return }
        embeddedLoop?.cancel()
        embeddedLoop = nil
        embeddedHost?.removeFromSuperview()
        embeddedHost = nil
        embeddedParent = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        onClose?()
        onClose = nil
    }

    /// Practice uses the browser's own content view, so typing and its coach
    /// remain in one window, including keyboard focus and accessibility.
    func showEmbedded(in view: NSView, contentFrame: NSRect) {
        embeddedParent = view
        embeddedContentFrame = contentFrame
        let host = NSHostingView(rootView: CommandBarView(model: model, close: { [weak self] in self?.close() }))
        host.setAccessibilityIdentifier("feather.tour.command-bar")
        host.wantsLayer = true
        embeddedHost = host
        view.addSubview(host)
        embeddedLoop = ObservationLoop { [weak self] in
            guard let self else { return }
            _ = self.model.suggestions.count
            self.layoutEmbedded()
        }
    }

    func updateEmbeddedLayout(contentFrame: NSRect) {
        guard embeddedContentFrame != contentFrame else { return }
        embeddedContentFrame = contentFrame
        layoutEmbedded()
    }

    private func layoutEmbedded() {
        guard let host = embeddedHost else { return }
        let width = max(280, min(Self.width, embeddedContentFrame.width - 24))
        if host.rootView.width != width { host.rootView.width = width }
        let height = min(host.fittingSize.height, max(54, embeddedContentFrame.height - 60))
        let frame = NSRect(x: embeddedContentFrame.midX - width / 2,
                            y: embeddedContentFrame.maxY - embeddedContentFrame.height * 0.18 - height,
                            width: width, height: height)
        if host.frame != frame {
            host.frame = frame
            onEmbeddedLayout?()
        }
    }

    /// Keeps the panel centered with a fixed top edge as suggestions resize it.
    func windowDidResize(_ notification: Notification) {
        guard topY != 0 else { return }
        let origin = NSPoint(x: centerX - panel.frame.width / 2, y: topY - panel.frame.height)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

final class CommandBarPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func performClose(_ sender: Any?) {
        onCancel?()
    }
}
