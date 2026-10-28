import Foundation

/// A named section of a space's tab list, like "Travel" or "AI Research".
/// Apple Intelligence makes these automatically; you can also make, rename,
/// and remove them yourself. Tabs stay in `Space.tabs`; a tab belongs to a
/// group through `Tab.groupID`.
@Observable
final class TabGroup: Identifiable {
    let id: UUID
    var name: String
    var collapsed: Bool
    /// Made by Apple Intelligence (shown with ✨).
    var automatic: Bool

    init(id: UUID = UUID(), name: String, collapsed: Bool = false, automatic: Bool) {
        self.id = id
        self.name = name
        self.collapsed = collapsed
        self.automatic = automatic
    }

    convenience init(record: TabGroupRecord) {
        self.init(id: record.id, name: record.name, collapsed: record.collapsed, automatic: record.automatic)
    }

    func record() -> TabGroupRecord {
        TabGroupRecord(id: id, name: name, collapsed: collapsed, automatic: automatic)
    }
}
