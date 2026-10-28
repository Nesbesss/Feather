import AppKit

/// An Arc-style space: its own pinned and regular tabs and, unless it is the
/// first space, its own website data store (cookies, logins, storage).
@Observable
final class Space: Identifiable {
    let id: UUID
    var name: String
    var hue: Double
    /// nil uses the app's default data store.
    let dataStoreID: UUID?
    var pinned: [Tab] = []
    var tabs: [Tab] = []
    /// Open tabs for Favorites, one per favorite at most.
    var favoriteTabs: [Tab] = []
    /// Named sections of the tab list, in order. Their tabs are the ones in `tabs` with a matching `groupID`.
    var groups: [TabGroup] = []
    var lastSelectedTabID: UUID?
    /// Tabs cleanup moved out of the sidebar, newest first. They reopen from the command bar.
    var archived: [ArchivedTabRecord] = []

    init(id: UUID = UUID(), name: String, hue: Double, dataStoreID: UUID?) {
        self.id = id
        self.name = name
        self.hue = hue
        self.dataStoreID = dataStoreID
    }

    convenience init(record: SpaceRecord) {
        self.init(id: record.id, name: record.name, hue: record.hue, dataStoreID: record.dataStoreID)
        pinned = record.pinned.map { Tab(record: $0) }
        tabs = record.tabs.map { Tab(record: $0) }
        favoriteTabs = (record.favoriteTabs ?? []).map { Tab(record: $0) }
        groups = (record.groups ?? []).map { TabGroup(record: $0) }
        lastSelectedTabID = record.lastSelectedTabID
        archived = record.archived ?? []
    }

    var allTabs: [Tab] { pinned + tabs + favoriteTabs }

    /// Lookups do not need to concatenate and copy every tab array.
    func firstTab(where matches: (Tab) -> Bool) -> Tab? {
        pinned.first(where: matches) ?? tabs.first(where: matches) ?? favoriteTabs.first(where: matches)
    }

    func contains(_ tab: Tab) -> Bool { firstTab { $0 === tab } != nil }

    func isPinned(_ tab: Tab) -> Bool { pinned.contains { $0 === tab } }

    func tab(for favorite: Favorite) -> Tab? { favoriteTabs.first { $0.favoriteID == favorite.id } }

    func group(of tab: Tab) -> TabGroup? { tab.groupID.flatMap { id in groups.first { $0.id == id } } }

    func tabs(in group: TabGroup) -> [Tab] { tabs.filter { $0.groupID == group.id } }

    /// Tabs in no (existing) group: new tabs land here, at the top.
    var looseTabs: [Tab] { tabs.filter { group(of: $0) == nil } }

    struct TabSections {
        var loose: [Tab]
        var grouped: [UUID: [Tab]]
    }

    /// One ephemeral partition for a sidebar render, instead of scanning all
    /// tabs again for each group. Unknown group IDs remain in the loose list.
    func tabSections() -> TabSections {
        let known = Set(groups.map(\.id))
        guard !known.isEmpty else { return TabSections(loose: tabs, grouped: [:]) }
        var loose: [Tab] = []
        var grouped: [UUID: [Tab]] = [:]
        for tab in tabs {
            if let id = tab.groupID, known.contains(id) {
                grouped[id, default: []].append(tab)
            } else {
                loose.append(tab)
            }
        }
        return TabSections(loose: loose, grouped: grouped)
    }

    /// Window and sidebar tint.
    func tint(dark: Bool) -> NSColor {
        dark ? NSColor(hue: hue, saturation: 0.35, brightness: 0.22, alpha: 1)
            : NSColor(hue: hue, saturation: 0.22, brightness: 0.93, alpha: 1)
    }

    func record() -> SpaceRecord {
        SpaceRecord(id: id, name: name, hue: hue, dataStoreID: dataStoreID,
                    pinned: pinned.map { $0.record() }, tabs: tabs.map { $0.record() },
                    lastSelectedTabID: lastSelectedTabID, archived: archived.isEmpty ? nil : archived,
                    favoriteTabs: favoriteTabs.isEmpty ? nil : favoriteTabs.map { $0.record() },
                    groups: groups.isEmpty ? nil : groups.map { $0.record() })
    }
}

/// What one browser window shows: a space, and one tab or two side by side.
@Observable
final class WindowState: Identifiable {
    let id = UUID()
    var space: Space
    var primary: Tab?
    /// The right-hand tab in split view.
    var secondary: Tab?
    var splitRatio = 0.5
    /// Whether keyboard commands target the right-hand pane.
    var focusSecondary = false
    var sidebarCollapsed = false
    @ObservationIgnored var restoredFrame: NSRect?

    init(space: Space) {
        self.space = space
    }

    var activeTab: Tab? { focusSecondary ? (secondary ?? primary) : primary }

    var visibleTabs: [Tab] { [primary, secondary].compactMap { $0 } }

    func isShowing(_ tab: Tab) -> Bool { primary === tab || secondary === tab }
}
