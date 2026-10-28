import Foundation
import os

/// Every few minutes, sorts each space's loose tabs into named groups once
/// there are enough of them, the way Safari does: Apple Intelligence writes a
/// short note per tab, the notes are embedded and clustered (`TabClustering`),
/// and each new group gets a name from its own tabs. Tabs you took out of a
/// group are left alone, and every change comes with Undo.
@Observable
final class TabGrouper {
    /// The space being organized right now, for the sidebar's "Organizing tabs…" line.
    private(set) var organizing: UUID?

    @ObservationIgnored private unowned let state: BrowserState
    @ObservationIgnored private var timer: Timer?
    /// Tabs already sent to the model per space, so the same tabs aren't asked about again.
    @ObservationIgnored private var considered: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "dev.nesbes.Feather", category: "TabGroups")

    static let minimumLoose = 6
    static let minimumNew = 3
    static let maxTabs = 40

    init(state: BrowserState) {
        self.state = state
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.organizeWhereNeeded() }
        }
        timer?.tolerance = 30
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in self?.organizeWhereNeeded() }
    }

    private static func host(of tab: Tab) -> String {
        tab.url?.host().map(Autocomplete.stripWWW) ?? ""
    }

    private func candidates(in space: Space, includingExcluded: Bool) -> [Tab] {
        space.looseTabs.filter { tab in
            (includingExcluded || !tab.noAutoGroup) && (tab.url?.scheme == "https" || tab.url?.scheme == "http")
        }
    }

    /// The timer's check: one space per round, only with enough new loose tabs.
    func organizeWhereNeeded() {
        guard state.settings.autoGroupTabs, AppleIntelligence.shared.isAvailable, organizing == nil else { return }
        for space in state.spaces {
            let loose = candidates(in: space, includingExcluded: false)
            let fresh = loose.filter { !(considered[space.id]?.contains($0.id) ?? false) }
            if loose.count >= Self.minimumLoose && fresh.count >= Self.minimumNew {
                Task { await organize(space, window: nil, manual: false) }
                return
            }
        }
    }

    /// Groups `space`'s loose tabs now. The banner goes to `window` (the key window if nil).
    func organize(_ space: Space, window: WindowState?, manual: Bool) async {
        guard organizing == nil else { return }
        if let reason = AppleIntelligence.shared.unavailableReason {
            if manual { state.toasts.show(reason, symbol: "sparkles", in: window?.id) }
            return
        }
        let tabs = Array(candidates(in: space, includingExcluded: manual).prefix(Self.maxTabs))
        guard tabs.count >= 2 else {
            if manual { state.toasts.show("Open a few more tabs, then group them", symbol: "sparkles", in: window?.id) }
            return
        }
        organizing = space.id
        defer { organizing = nil }
        considered[space.id, default: []].formUnion(tabs.map(\.id))
        let started = Date()

        // Tabs already in groups anchor them, so new tabs can join (Safari's "attach mode").
        let anchors = space.groups.flatMap { group in space.tabs(in: group).prefix(6).map { (tab: $0, group: group) } }
        let all = tabs + anchors.map(\.tab)

        // 1. A note per tab ("Travel: planning a trip to Lisbon"), kept on the tab until its page changes.
        for tab in all {
            guard let url = tab.url?.absoluteString, tab.note == nil || tab.noteURL != url else { continue }
            if let note = await AppleIntelligence.shared.describeTab(title: tab.displayTitle, host: Self.host(of: tab),
                                                                    summary: tab.summary) {
                tab.note = note
                tab.noteURL = url
            }
        }

        // 2. Embed the notes and find groups: loose tabs near an existing group join it; the rest cluster.
        var joining: [(group: TabGroup, tabs: [Tab])] = []
        var clusters: [[Tab]] = []
        let texts = all.map { $0.note ?? "\(TabClustering.siteName(Self.host(of: $0))) \($0.displayTitle)" }
        if let vectors = await TabEmbedder.shared.vectors(for: texts) {
            let distances = TabClustering.distances(vectors)
            let groups = space.groups.filter { group in anchors.contains { $0.group === group } }
            let anchorSets = groups.map { group in anchors.indices.filter { anchors[$0].group === group }.map { $0 + tabs.count } }
            joining = groups.map { ($0, []) }
            var remaining: [Int] = []
            for index in tabs.indices {
                if let target = TabClustering.attach(index, to: anchorSets, distances) {
                    joining[target].tabs.append(tabs[index])
                } else {
                    remaining.append(index)
                }
            }
            clusters = TabClustering.groups(of: remaining, distances).map { $0.map { tabs[$0] } }
        } else {
            // Without the embedding model, notes that share a topic make a group.
            clusters = TabClustering.groupsByTopic(tabs.map(\.note)).map { $0.map { tabs[$0] } }
        }

        // 3. Name each new group from its own tabs; a name that matches an existing group joins it.
        var named: [(name: String, tabs: [Tab])] = []
        for cluster in clusters {
            let suggested = await AppleIntelligence.shared.nameGroup(titles: cluster.map(\.displayTitle),
                                                                     notes: cluster.map { $0.note ?? "" })
            let topic = cluster.first?.note?.split(separator: ":").first.map(String.init) ?? ""
            let name = TabClustering.cleanName(suggested ?? topic)
            if !name.isEmpty { named.append((name, cluster)) }
        }
        log.info("Organized \(tabs.count) tabs in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s: \(joining.reduce(0) { $0 + $1.tabs.count }) joined, \(named.count) new groups")

        // Tabs may have closed or been grouped by hand while the model was thinking.
        func stillLoose(_ tab: Tab) -> Bool { space.tabs.contains { $0 === tab } && space.group(of: tab) == nil }
        var previous: [(tab: Tab, groupID: UUID?)] = []
        var created: [TabGroup] = []
        var names: [String] = []
        func put(_ members: [Tab], in group: TabGroup) {
            for tab in members where stillLoose(tab) {
                previous.append((tab, tab.groupID))
                tab.groupID = group.id
                tab.noAutoGroup = false
            }
            if !names.contains(group.name) { names.append(group.name) }
        }
        for (group, members) in joining where !members.isEmpty && space.groups.contains(where: { $0 === group }) {
            put(members, in: group)
        }
        for (name, members) in named where members.filter(stillLoose).count >= TabClustering.minimumGroupSize {
            if let existing = space.groups.first(where: { $0.name.lowercased() == name.lowercased() }) {
                put(members, in: existing)
            } else {
                let group = TabGroup(name: name, automatic: true)
                space.groups.append(group)
                created.append(group)
                put(members, in: group)
            }
        }
        guard !previous.isEmpty else {
            if manual { state.toasts.show("These tabs don't have much in common yet", symbol: "sparkles", in: window?.id) }
            return
        }
        state.scheduleSave()
        let shown = names.count > 3 ? names.prefix(2) + ["\(names.count - 2) more"] : names[...]
        let list = ListFormatter.localizedString(byJoining: Array(shown))
        state.toasts.show("Grouped \(previous.count) tabs into \(list)", symbol: "sparkles", in: window?.id, actions: [
            .init(title: "Undo") { [weak self] in
                for (tab, groupID) in previous { tab.groupID = groupID }
                space.groups.removeAll { group in created.contains { $0 === group } && space.tabs(in: group).isEmpty }
                self?.state.scheduleSave()
            },
        ], duration: 8)
    }
}
