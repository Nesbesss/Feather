import AppKit
import WebKit

/// The whole browser: spaces, windows, and every tab operation. UI layers call
/// into this; it keeps the model consistent and tells `TabLifecycle` which tabs
/// must be live.
@Observable
final class BrowserState {
    var spaces: [Space] = []
    /// The sidebar's Favorites grid, the same in every space.
    var favorites: [Favorite] = []
    var windows: [WindowState] = []
    /// The window commands go to.
    var keyWindow: WindowState?
    /// On battery or in Low Power Mode with battery saver on; tabs sleep sooner.
    var batterySaverActive = false
    /// Visible session-only status; the AppDelegate owns the local agent bridge.
    var agentAccessEnabled = false

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let persistent: Bool
    @ObservationIgnored private(set) var recentlyClosed: [ClosedTabRecord] = []
    @ObservationIgnored private(set) lazy var lifecycle = TabLifecycle(state: self)
    @ObservationIgnored private(set) lazy var media = MediaController(state: self)
    @ObservationIgnored private(set) lazy var smartSidebar = SmartSidebar(state: self)
    @ObservationIgnored private(set) lazy var grouper = TabGrouper(state: self)
    @ObservationIgnored let history: HistoryStore?
    @ObservationIgnored private let session: SessionStore?
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private var archiveTimer: Timer?
    /// Called when a window model needs an on-screen window.
    @ObservationIgnored var onOpenWindow: ((WindowState) -> Void)?
    @ObservationIgnored var onCloseWindow: ((WindowState) -> Void)?
    /// Open sign-in popups, retained while their windows are up.
    @ObservationIgnored var popups: [PopupWindowController] = []

    let memory: MemoryMonitor
    let downloads = DownloadManager()
    let toasts = ToastCenter()

    init(settings: AppSettings, persistent: Bool) {
        self.settings = settings
        self.persistent = persistent
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Feather", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        session = persistent ? SessionStore(url: support.appendingPathComponent("session.json")) : nil
        history = persistent ? HistoryStore(url: support.appendingPathComponent("history.sqlite")) : nil
        memory = MemoryMonitor()
        memory.state = self
        toasts.defaultWindowID = { [unowned self] in keyWindow?.id ?? windows.first?.id }
        downloads.onFinish = { [unowned self] item in
            toasts.show("Downloaded \(item.filename)", symbol: "arrow.down.circle.fill", actions: [
                .init(title: "Show in Finder") { [unowned self] in downloads.reveal(item) },
                .init(title: "Open", isPrimary: true) { [unowned self] in downloads.open(item) },
            ], duration: 8)
        }
    }

    // MARK: Lookup

    func space(of tab: Tab) -> Space? { spaces.first { $0.contains(tab) } }

    func window(showing tab: Tab) -> WindowState? { windows.first { $0.isShowing(tab) } }

    func tab(id: UUID) -> Tab? {
        for space in spaces {
            if let tab = space.firstTab(where: { $0.id == id }) { return tab }
        }
        return nil
    }

    /// The live tab whose web view this is, if any (popup windows have none).
    func tab(showing webView: WKWebView?) -> Tab? {
        guard let webView else { return nil }
        for space in spaces {
            if let tab = space.firstTab(where: { $0.webView === webView }) { return tab }
        }
        return nil
    }

    var allTabs: [Tab] { spaces.flatMap(\.allTabs) }

    var liveTabs: [Tab] {
        var live: [Tab] = []
        for space in spaces {
            for list in [space.pinned, space.tabs, space.favoriteTabs] {
                for tab in list where tab.isLive { live.append(tab) }
            }
        }
        return live
    }

    // MARK: Windows

    @discardableResult
    func newWindow(space: Space? = nil) -> WindowState {
        let window = WindowState(space: space ?? keyWindow?.space ?? spaces[0])
        windows.append(window)
        onOpenWindow?(window)
        lifecycle.factory.extensions.didOpenWindow(window)
        if let tab = window.space.allTabs.first(where: { $0.id == window.space.lastSelectedTabID && self.window(showing: $0) == nil }) {
            select(tab, in: window)
        }
        return window
    }

    func windowDidClose(_ window: WindowState) {
        for tab in window.visibleTabs { tab.lastActive = .now }
        windows.removeAll { $0 === window }
        lifecycle.factory.extensions.didCloseWindow(window)
        if keyWindow === window { keyWindow = windows.first }
        lifecycle.scheduleEvaluation()
        scheduleSave()
    }

    /// Auxiliary pages keep their creation data store even if their opener moves.
    /// Reuse only an owner-space window, leaving other spaces' windows in place.
    func auxiliaryTabTarget(spaceID: UUID, opener: Tab?) -> (window: WindowState, anchor: Tab?)? {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return nil }
        let anchor = opener.flatMap { space.contains($0) ? $0 : nil }
        let openerWindow = anchor.flatMap { self.window(showing: $0) }.flatMap { $0.space === space ? $0 : nil }
        let ownerKeyWindow = keyWindow.flatMap { $0.space === space ? $0 : nil }
        let targetWindow = openerWindow ?? ownerKeyWindow ?? windows.first(where: { $0.space === space })
            ?? newWindow(space: space)
        return (targetWindow, anchor)
    }

    // MARK: Tabs

    /// Opens a tab after `anchor`, or at the top of the space's list like Arc.
    /// Background tabs stay asleep until selected when lazy loading is on.
    @discardableResult
    func openTab(_ url: URL?, in window: WindowState, background: Bool = false, after anchor: Tab? = nil,
                 fallbacks: [URL] = [], configuration: WKWebViewConfiguration? = nil) -> Tab {
        let tab = Tab(url: url)
        tab.fallbackURLs = fallbacks
        let space = (anchor.flatMap(space(of:))) ?? window.space
        if let anchor, let index = space.tabs.firstIndex(where: { $0 === anchor }) {
            space.tabs.insert(tab, at: index + 1)
            tab.groupID = space.group(of: anchor)?.id
        } else {
            space.tabs.insert(tab, at: 0)
        }
        lifecycle.factory.extensions.didOpen(tab, in: space)
        if let configuration {
            lifecycle.wake(tab, in: space, configuration: configuration)
        } else if background && !settings.lazyBackgroundTabs {
            lifecycle.wake(tab, in: space)
        }
        if !background { select(tab, in: window) }
        scheduleSave()
        return tab
    }

    /// Moves an existing web view (a popup's) into a new tab next to `anchor`.
    @discardableResult
    func adopt(_ webView: WKWebView, in window: WindowState, after anchor: Tab?) -> Tab {
        let tab = Tab(url: webView.url)
        let space = anchor.flatMap(space(of:)) ?? window.space
        let index = anchor.flatMap { anchor in space.tabs.firstIndex { $0 === anchor } }.map { $0 + 1 } ?? 0
        space.tabs.insert(tab, at: index)
        tab.controller = WebTabController(tab: tab, webView: webView, state: self)
        tab.webView = webView
        lifecycle.factory.extensions.bind(webView, to: tab, in: space)
        select(tab, in: window)
        scheduleSave()
        return tab
    }

    /// Shows `tab` in the window's focused pane, waking it if it sleeps.
    func select(_ tab: Tab, in window: WindowState) {
        let previousSpace = window.space
        if let other = self.window(showing: tab), other !== window {
            take(tab, from: other)
        }
        for shown in window.visibleTabs where shown !== tab { shown.lastActive = .now }
        if let space = space(of: tab), window.space !== space { window.space = space }

        if window.primary === tab {
            window.focusSecondary = false
        } else if window.secondary === tab {
            window.focusSecondary = true
        } else if window.secondary != nil && window.focusSecondary {
            window.secondary = tab
        } else {
            window.primary = tab
        }
        tab.lastActive = .now
        window.space.lastSelectedTabID = tab.id
        if previousSpace !== window.space {
            lifecycle.factory.extensions.didSwitchSpace(in: window, from: previousSpace)
        }
        lifecycle.ensureLive(tab)
        lifecycle.factory.extensions.didSelect(tab, in: window.space)
        lifecycle.scheduleEvaluation()
        scheduleSave()
    }

    func close(_ tab: Tab) {
        guard let space = space(of: tab) else { return }
        lifecycle.factory.extensions.didClose(tab, in: space)
        let record = tab.record()
        let replacement = nextTab(after: tab, in: space, excluding: nil)
        if let index = space.tabs.firstIndex(where: { $0 === tab }) {
            recentlyClosed.append(ClosedTabRecord(tab: record, spaceID: space.id, index: index))
            space.tabs.remove(at: index)
        } else if let index = space.pinned.firstIndex(where: { $0 === tab }) {
            recentlyClosed.append(ClosedTabRecord(tab: record, spaceID: space.id, index: -1 - index))
            space.pinned.remove(at: index)
        } else {
            // A Favorite's tab: the tile stays, and opens the saved page again next time.
            space.favoriteTabs.removeAll { $0 === tab }
        }
        if recentlyClosed.count > 50 { recentlyClosed.removeFirst(recentlyClosed.count - 50) }
        pruneGroups(in: space)
        lifecycle.discard(tab)
        for window in windows where window.isShowing(tab) {
            let fallback = replacement.flatMap { window.isShowing($0) || self.window(showing: $0) != nil ? nil : $0 }
            window.remove(tab, fallback: fallback)
            if let shown = window.activeTab { select(shown, in: window) }
        }
        scheduleSave()
    }

    func reopenClosedTab(in window: WindowState) {
        guard let closed = recentlyClosed.popLast() else { return }
        let space = spaces.first { $0.id == closed.spaceID } ?? window.space
        let tab = Tab(record: closed.tab)
        if closed.index < 0 {
            space.pinned.insert(tab, at: min(-1 - closed.index, space.pinned.count))
        } else {
            space.tabs.insert(tab, at: min(closed.index, space.tabs.count))
        }
        select(tab, in: window)
    }

    func togglePin(_ tab: Tab) {
        guard tab.favoriteID == nil, let space = space(of: tab) else { return }
        if let index = space.pinned.firstIndex(where: { $0 === tab }) {
            space.pinned.remove(at: index)
            space.tabs.insert(tab, at: 0)
        } else if let index = space.tabs.firstIndex(where: { $0 === tab }) {
            space.tabs.remove(at: index)
            tab.groupID = nil
            space.pinned.append(tab)
            pruneGroups(in: space)
        }
        scheduleSave()
    }

    func moveTabs(in space: Space, from source: IndexSet, to destination: Int) {
        space.tabs.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    /// Reorders within one section of the tab list (loose tabs or one group), leaving the others in place.
    func moveTabs(in space: Space, among section: [Tab], from source: IndexSet, to destination: Int) {
        var reordered = section
        reordered.move(fromOffsets: source, toOffset: destination)
        let slots = space.tabs.indices.filter { index in section.contains { $0 === space.tabs[index] } }
        for (slot, tab) in zip(slots, reordered) { space.tabs[slot] = tab }
        scheduleSave()
    }

    func move(_ tab: Tab, to target: Space) {
        guard tab.favoriteID == nil, let source = space(of: tab), source !== target else { return }
        // A web view can't change data stores, so the tab sleeps and reloads in the new space.
        lifecycle.discard(tab, keepingState: true)
        source.tabs.removeAll { $0 === tab }
        source.pinned.removeAll { $0 === tab }
        tab.groupID = nil
        pruneGroups(in: source)
        target.tabs.insert(tab, at: 0)
        for window in windows where window.isShowing(tab) {
            take(tab, from: window, fallbackSpace: source)
        }
        scheduleSave()
    }

    func selectTab(atIndex index: Int, in window: WindowState) {
        let tabs = window.space.allTabs
        guard !tabs.isEmpty else { return }
        select(index == 8 ? tabs[tabs.count - 1] : tabs[min(index, tabs.count - 1)], in: window)
    }

    func selectAdjacentTab(offset: Int, in window: WindowState) {
        let tabs = window.space.allTabs
        guard !tabs.isEmpty else { return }
        let current = window.activeTab.flatMap { tab in tabs.firstIndex { $0 === tab } } ?? 0
        select(tabs[(current + offset + tabs.count) % tabs.count], in: window)
    }

    /// Removes `tab` from a window's panes; whatever that window shows instead is woken.
    private func take(_ tab: Tab, from window: WindowState, fallbackSpace: Space? = nil) {
        window.remove(tab, fallback: nextTab(after: tab, in: fallbackSpace ?? window.space, excluding: window))
        window.visibleTabs.forEach(lifecycle.ensureLive)
    }

    /// Next tab to show when `tab` goes away: below it, else above it, else pinned.
    private func nextTab(after tab: Tab, in space: Space, excluding window: WindowState?) -> Tab? {
        let candidates = space.allTabs.filter { $0 !== tab && (self.window(showing: $0) == nil || self.window(showing: $0) === window) }
        let list = space.allTabs
        guard let index = list.firstIndex(where: { $0 === tab }) else { return candidates.first }
        let after = list[(index + 1)...].first { tab in candidates.contains { $0 === tab } }
        let before = list[..<index].last { tab in candidates.contains { $0 === tab } }
        return after ?? before
    }

    // MARK: Tab groups

    @discardableResult
    func newGroup(named name: String, with tabs: [Tab], in space: Space) -> TabGroup {
        let group = TabGroup(name: name, automatic: false)
        space.groups.append(group)
        for tab in tabs where space.tabs.contains(where: { $0 === tab }) {
            tab.groupID = group.id
            tab.noAutoGroup = false
        }
        pruneGroups(in: space)
        scheduleSave()
        return group
    }

    /// Puts a tab in a group, or takes it out (nil); a tab you take out isn't regrouped automatically.
    func move(_ tab: Tab, toGroup group: TabGroup?) {
        guard let space = space(of: tab), space.tabs.contains(where: { $0 === tab }) else { return }
        tab.groupID = group?.id
        tab.noAutoGroup = group == nil
        pruneGroups(in: space)
        scheduleSave()
    }

    /// Dissolves a group; its tabs go back to the loose list and stay out of automatic grouping.
    func ungroup(_ group: TabGroup, in space: Space) {
        for tab in space.tabs(in: group) {
            tab.groupID = nil
            tab.noAutoGroup = true
        }
        space.groups.removeAll { $0 === group }
        scheduleSave()
    }

    func closeTabs(in group: TabGroup, in space: Space) {
        space.tabs(in: group).forEach(close)
    }

    func rename(_ group: TabGroup, to name: String) {
        group.name = name
        group.automatic = false
        scheduleSave()
    }

    func toggleCollapsed(_ group: TabGroup) {
        group.collapsed.toggle()
        scheduleSave()
    }

    /// Groups with no tabs left disappear.
    func pruneGroups(in space: Space) {
        let used = Set(space.tabs.compactMap(\.groupID))
        if space.groups.contains(where: { !used.contains($0.id) }) { space.groups.removeAll { !used.contains($0.id) } }
    }

    // MARK: Favorites

    func favorite(of tab: Tab) -> Favorite? {
        tab.favoriteID.flatMap { id in favorites.first { $0.id == id } }
    }

    /// Shows the favorite's tab in this window's space, opening it at the saved page if needed.
    /// Clicking a favorite you're already on that has wandered off takes it back to the saved page.
    func open(_ favorite: Favorite, in window: WindowState) {
        let space = window.space
        if let tab = space.tab(for: favorite) {
            if window.isShowing(tab), !favorite.isAtSavedPage(tab.url) {
                lifecycle.load(favorite.url, fallbacks: [], in: tab)
            }
            select(tab, in: window)
            return
        }
        let tab = Tab(url: favorite.url, title: favorite.title)
        tab.favoriteID = favorite.id
        space.favoriteTabs.append(tab)
        select(tab, in: window)
    }

    /// Takes the favorite's tab back to the saved page.
    func goToSavedPage(of favorite: Favorite, in window: WindowState) {
        guard let tab = window.space.tab(for: favorite) else { return open(favorite, in: window) }
        lifecycle.load(favorite.url, fallbacks: [], in: tab)
        select(tab, in: window)
    }

    /// Makes `tab` a Favorite. The tab itself moves into the grid, like dragging it there in Arc.
    func addFavorite(from tab: Tab, window: WindowState? = nil) {
        guard tab.favoriteID == nil, let url = tab.url, url.scheme == "https" || url.scheme == "http",
              let space = space(of: tab) else { return }
        if let existing = favorites.first(where: { $0.isAtSavedPage(url) }) {
            toasts.show("\(existing.displayTitle) is already in Favorites", symbol: "star.fill", in: window?.id)
            return
        }
        let favorite = Favorite(url: url, title: tab.title)
        favorites.append(favorite)
        if space.tab(for: favorite) == nil {
            space.tabs.removeAll { $0 === tab }
            space.pinned.removeAll { $0 === tab }
            tab.favoriteID = favorite.id
            space.favoriteTabs.append(tab)
        }
        toasts.show("Added \(favorite.displayTitle) to Favorites", symbol: "star.fill", in: window?.id, actions: [
            .init(title: "Undo") { [weak self] in self?.removeFavorite(favorite, announce: false) },
        ], duration: 6)
        scheduleSave()
    }

    /// Adds a suggested site without opening it.
    func addFavorite(url: URL, title: String) {
        guard !favorites.contains(where: { $0.isAtSavedPage(url) }) else { return }
        favorites.append(Favorite(url: url, title: title))
        scheduleSave()
    }

    /// Removes a favorite. Its open tabs stay open, at the top of each space's tab list.
    func removeFavorite(_ favorite: Favorite, window: WindowState? = nil, announce: Bool = true) {
        guard let index = favorites.firstIndex(where: { $0 === favorite }) else { return }
        favorites.remove(at: index)
        var released: [(Tab, Space)] = []
        for space in spaces {
            guard let tab = space.tab(for: favorite) else { continue }
            space.favoriteTabs.removeAll { $0 === tab }
            tab.favoriteID = nil
            space.tabs.insert(tab, at: 0)
            released.append((tab, space))
        }
        scheduleSave()
        guard announce else { return }
        toasts.show("Removed \(favorite.displayTitle) from Favorites", symbol: "star.slash", in: window?.id, actions: [
            .init(title: "Undo") { [weak self] in
                guard let self, !self.favorites.contains(where: { $0 === favorite }) else { return }
                self.favorites.insert(favorite, at: min(index, self.favorites.count))
                for (tab, space) in released where space.tabs.contains(where: { $0 === tab }) {
                    space.tabs.removeAll { $0 === tab }
                    tab.favoriteID = favorite.id
                    space.favoriteTabs.append(tab)
                }
                self.scheduleSave()
            },
        ], duration: 6)
    }

    /// Saves where the favorite's tab is now as its page.
    func setSavedPage(of favorite: Favorite, to tab: Tab) {
        guard let url = tab.url else { return }
        favorite.url = url
        if !tab.title.isEmpty { favorite.title = tab.title }
        scheduleSave()
    }

    func moveFavorite(_ favorite: Favorite, before target: Favorite?) {
        guard favorite !== target, let from = favorites.firstIndex(where: { $0 === favorite }) else { return }
        favorites.remove(at: from)
        let to = target.flatMap { target in favorites.firstIndex { $0 === target } } ?? favorites.count
        favorites.insert(favorite, at: to)
        scheduleSave()
    }

    /// Most visited sites (any space) not already in Favorites.
    func favoriteSuggestions() -> [FavoriteSuggestions.Site] {
        FavoriteSuggestions.suggestions(visits: history?.visitsByHost() ?? [:], existing: Set(favorites.map(\.host)))
    }

    // MARK: Reader

    func toggleReader(_ tab: Tab) {
        guard let webView = tab.webView else { return }
        Task { tab.isReaderOpen = await ReaderMode.toggle(in: webView, fontSize: settings.readerFontSize) }
    }

    // MARK: Archive

    /// Moves unpinned tabs out of the sidebar into their space's archive, keeping
    /// their history, and offers Undo.
    func archive(_ tabs: [Tab], in space: Space, message: String? = nil, window: WindowState? = nil) {
        let now = Date.now
        // Positions and windows are taken before anything moves, so Undo puts back exactly this.
        let targets = tabs.compactMap { tab in
            space.tabs.firstIndex { $0 === tab }.map { (tab: tab, index: $0, shownIn: windows.filter { $0.isShowing(tab) }) }
        }
        var moved: [(record: ArchivedTabRecord, index: Int, shownIn: [WindowState])] = []
        for target in targets.sorted(by: { $0.index > $1.index }) {  // back to front keeps indices valid
            lifecycle.factory.extensions.didClose(target.tab, in: space)
            lifecycle.discard(target.tab, keepingState: true)
            moved.insert((ArchivedTabRecord(tab: target.tab.record(), archivedAt: now), target.index, target.shownIn), at: 0)
            space.tabs.remove(at: target.index)
        }
        for target in targets {
            for window in target.shownIn { take(target.tab, from: window) }
        }
        guard !moved.isEmpty else { return }
        space.archived.insert(contentsOf: moved.map(\.record), at: 0)
        trimArchive(of: space)
        let groupsBefore = space.groups
        pruneGroups(in: space)
        scheduleSave()

        let count = moved.count
        let text = message ?? (count == 1 ? "Archived 1 tab" : "Archived \(count) tabs")
        toasts.show(text, symbol: "archivebox", in: window?.id, actions: [.init(title: "Undo") { [weak self, weak space] in
            guard let self, let space else { return }
            let ids = Set(moved.map(\.record.tab.id))
            space.archived.removeAll { ids.contains($0.tab.id) }
            // Groups that emptied come back with their tabs, in their old order.
            space.groups = groupsBefore + space.groups.filter { group in !groupsBefore.contains { $0 === group } }
            // Ascending order puts every tab back at its old position.
            for item in moved.sorted(by: { $0.index < $1.index }) {
                let tab = Tab(record: item.record.tab)
                space.tabs.insert(tab, at: min(item.index, space.tabs.count))
                for window in item.shownIn where window.space === space { self.select(tab, in: window) }
            }
            self.scheduleSave()
        }], duration: 10)
    }

    /// The sidebar's Clear button: every unpinned tab except ones with unsaved typing.
    func clearTabs(in window: WindowState) {
        archive(window.space.tabs.filter { !$0.hasUnsavedInput }, in: window.space, window: window)
    }

    /// Reopens an archived tab with its history, at the top of the space's tabs.
    func restoreArchived(_ id: UUID, in space: Space, window: WindowState) {
        guard let index = space.archived.firstIndex(where: { $0.tab.id == id }) else { return }
        let tab = Tab(record: space.archived.remove(at: index).tab)
        tab.lastActive = .now
        if space.group(of: tab) == nil { tab.groupID = nil }
        space.tabs.insert(tab, at: 0)
        select(tab, in: window)
        scheduleSave()
    }

    /// Periodic cleanup of tabs nobody has looked at for `settings.archiveAfterHours`.
    func archiveIdleTabs(now: Date = .now) {
        let hours = settings.archiveAfterHours
        guard hours > 0 else { return }
        for space in spaces {
            let facts = space.tabs.map { tab in
                ArchivePolicy.Facts(id: tab.id, lastActive: tab.lastActive, isVisible: window(showing: tab) != nil,
                                    isPlayingAudio: tab.isPlayingAudio, hasUnsavedInput: tab.hasUnsavedInput)
            }
            let ids = Set(ArchivePolicy.tabsToArchive(facts, now: now, after: TimeInterval(hours) * 3600))
            guard !ids.isEmpty else { continue }
            let label = hours >= 48 ? "\(Int(hours / 24)) days" : "\(Int(hours)) hours"
            let count = ids.count
            archive(space.tabs.filter { ids.contains($0.id) }, in: space,
                    message: "Archived \(count) \(count == 1 ? "tab" : "tabs") unused for \(label). Find them with ⌘T.")
        }
    }

    private func trimArchive(of space: Space) {
        if space.archived.count > ArchivePolicy.maxArchived {
            space.archived.removeLast(space.archived.count - ArchivePolicy.maxArchived)
        }
        for index in space.archived.indices.dropFirst(ArchivePolicy.maxWithHistory)
        where space.archived[index].tab.interactionState != nil {
            space.archived[index].tab.interactionState = nil
        }
    }

    // MARK: Navigation

    /// Runs what the user typed: navigates the active tab, or opens a new one.
    func go(to text: String, in window: WindowState, newTab: Bool) {
        let target: URL
        var fallbacks: [URL] = []
        switch URLInput.resolve(text) {
        case .url(let url, let urlFallbacks)?:
            target = url
            fallbacks = urlFallbacks
        case .search(let query)?:
            guard let url = URLInput.searchURL(for: query, template: settings.searchEngine.template) else { return }
            target = url
        case nil:
            return
        }
        if let scheme = target.scheme?.lowercased(), URLInput.systemSchemes.contains(scheme) {
            NSWorkspace.shared.open(target)
            return
        }
        if newTab || window.activeTab == nil {
            openTab(target, in: window, fallbacks: fallbacks)
        } else if let tab = window.activeTab {
            lifecycle.load(target, fallbacks: fallbacks, in: tab)
        }
    }

    // MARK: Split view

    /// Splits the window with the next tab, or unsplits it.
    func toggleSplit(in window: WindowState) {
        if let secondary = window.secondary {
            secondary.lastActive = .now
            window.secondary = nil
            window.focusSecondary = false
            lifecycle.scheduleEvaluation()
            scheduleSave()
        } else if let primary = window.primary {
            let partner = nextTab(after: primary, in: window.space, excluding: window)
                ?? openTab(nil, in: window, background: true, after: primary)
            showInSplit(partner, in: window)
        }
    }

    /// Shows `tab` in the right-hand pane next to the current tab.
    func showInSplit(_ tab: Tab, in window: WindowState) {
        guard let primary = window.primary, primary !== tab else { return select(tab, in: window) }
        if let other = self.window(showing: tab), other !== window {
            take(tab, from: other)
        }
        window.secondary?.lastActive = .now
        window.secondary = tab
        select(tab, in: window)
    }

    // MARK: Spaces

    private static let spaceHues = [0.60, 0.33, 0.08, 0.80, 0.50, 0.95, 0.15]

    @discardableResult
    func addSpace(named name: String) -> Space {
        let hue = Self.spaceHues[spaces.count % Self.spaceHues.count]
        let space = Space(name: name, hue: hue, dataStoreID: spaces.isEmpty ? nil : UUID())
        spaces.append(space)
        scheduleSave()
        return space
    }

    func switchToSpace(_ space: Space, in window: WindowState) {
        guard window.space !== space else { return }
        let previousSpace = window.space
        for tab in window.visibleTabs { tab.lastActive = .now }
        window.space = space
        window.primary = nil
        window.secondary = nil
        window.focusSecondary = false
        lifecycle.factory.extensions.didSwitchSpace(in: window, from: previousSpace)
        if let tab = space.allTabs.first(where: { $0.id == space.lastSelectedTabID && self.window(showing: $0) == nil })
            ?? space.allTabs.first(where: { self.window(showing: $0) == nil }) {
            select(tab, in: window)
        }
        lifecycle.scheduleEvaluation()
        scheduleSave()
    }

    /// Deletes a space with its tabs and its cookies, storage, and cache.
    func deleteSpace(_ space: Space) {
        guard spaces.count > 1, spaces.contains(where: { $0 === space }),
              let fallback = spaces.first(where: { $0 !== space }) else { return }
        PeekWindowController.dismiss(inSpace: space.id)
        let ownedPopups = popups.filter { $0.spaceID == space.id }
        ownedPopups.forEach { $0.close() }
        for tab in space.allTabs { lifecycle.discard(tab) }
        lifecycle.factory.extensions.forget(space)
        spaces.removeAll { $0 === space }
        for window in windows where window.space === space { switchToSpace(fallback, in: window) }
        if let id = space.dataStoreID {
            lifecycle.factory.forgetDataStore(id)
            Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        }
        scheduleSave()
    }

    // MARK: Persistence

    /// Restores the last session. Only the tabs windows show are loaded.
    func restore() {
        if let record = session?.load(), !record.spaces.isEmpty {
            spaces = record.spaces.map { Space(record: $0) }
            favorites = (record.favorites ?? []).compactMap(Favorite.init(record:))
            recentlyClosed = record.recentlyClosed
            // A tab whose Favorite is gone becomes a regular tab.
            let ids = Set(favorites.map(\.id))
            for space in spaces {
                let orphans = space.favoriteTabs.filter { !ids.contains($0.favoriteID ?? UUID()) }
                orphans.forEach { $0.favoriteID = nil }
                space.favoriteTabs.removeAll { $0.favoriteID == nil }
                space.tabs.insert(contentsOf: orphans, at: 0)
            }
            for windowRecord in record.windows {
                guard let space = spaces.first(where: { $0.id == windowRecord.spaceID }) else { continue }
                let window = WindowState(space: space)
                window.primary = windowRecord.primaryTabID.flatMap(tab(id:))
                window.secondary = windowRecord.secondaryTabID.flatMap(tab(id:))
                window.splitRatio = windowRecord.splitRatio
                window.sidebarCollapsed = windowRecord.sidebarCollapsed
                window.restoredFrame = windowRecord.frame.map(NSRectFromString)
                windows.append(window)
            }
        }
        if spaces.isEmpty { addSpace(named: "Home") }
        if windows.isEmpty { windows.append(WindowState(space: spaces[0])) }
        for window in windows {
            onOpenWindow?(window)
            for tab in window.visibleTabs { lifecycle.ensureLive(tab) }
        }
        keyWindow = windows.first
        if persistent {
            grouper.start()
            archiveIdleTabs()
            archiveTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.archiveIdleTabs() }
            }
        }
    }

    func scheduleSave() {
        guard session != nil, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.saveScheduled = false
            self?.saveNow()
        }
    }

    func saveNow(synchronously: Bool = false) {
        guard let session else { return }
        let record = SessionRecord(
            spaces: spaces.map { $0.record() },
            windows: windows.map { window in
                WindowRecord(spaceID: window.space.id, primaryTabID: window.primary?.id, secondaryTabID: window.secondary?.id,
                             splitRatio: window.splitRatio, frame: window.currentFrame.map(NSStringFromRect),
                             sidebarCollapsed: window.sidebarCollapsed)
            },
            recentlyClosed: recentlyClosed,
            favorites: favorites.map { $0.record() })
        session.save(record, synchronously: synchronously)
    }
}

extension WindowState {
    /// Removes a tab from its pane. A split collapses to the remaining tab.
    func remove(_ tab: Tab, fallback: Tab?) {
        if secondary === tab {
            secondary = nil
            focusSecondary = false
        } else if primary === tab {
            if let secondary {
                primary = secondary
                self.secondary = nil
                focusSecondary = false
            } else {
                primary = fallback
            }
        }
    }

    /// Frame of the on-screen window, set by its controller.
    var currentFrame: NSRect? {
        WindowFrames.frames[id]
    }
}

/// On-screen frames by window, kept outside the observable model so window
/// moves don't trigger UI updates.
enum WindowFrames {
    static var frames: [UUID: NSRect] = [:]
}
