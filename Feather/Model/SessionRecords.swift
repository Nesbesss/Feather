import Foundation

// Plain, Codable snapshots of the browser state, written to
// ~/Library/Application Support/Feather/session.json. A tab's
// `interactionState` is WebKit's opaque back/forward + scroll state, so a
// restored tab can rebuild its history without being loaded at launch.

nonisolated struct SessionRecord: Codable, Equatable, Sendable {
    var version = 1
    var spaces: [SpaceRecord]
    var windows: [WindowRecord]
    var recentlyClosed: [ClosedTabRecord] = []
    /// The sidebar's Favorites, shared by every space. Missing in older session files.
    var favorites: [FavoriteRecord]?
}

nonisolated struct FavoriteRecord: Codable, Equatable, Sendable {
    var id: UUID
    var url: String
    var title: String
}

nonisolated struct SpaceRecord: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var hue: Double
    var dataStoreID: UUID?
    var pinned: [TabRecord]
    var tabs: [TabRecord]
    var lastSelectedTabID: UUID?
    /// Tabs moved out of the sidebar by cleanup, newest first. Missing in older session files.
    var archived: [ArchivedTabRecord]?
    /// This space's open tabs for Favorites (each has `favoriteID`). Missing in older session files.
    var favoriteTabs: [TabRecord]?
    /// Named sections of the tab list. Missing in older session files.
    var groups: [TabGroupRecord]?
}

nonisolated struct TabGroupRecord: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var collapsed: Bool
    /// Made by Apple Intelligence rather than by hand.
    var automatic: Bool
}

nonisolated struct ArchivedTabRecord: Codable, Equatable, Sendable {
    var tab: TabRecord
    var archivedAt: Date
}

nonisolated struct TabRecord: Codable, Equatable, Sendable {
    var id: UUID
    var url: String?
    var title: String
    var lastActive: Date
    var interactionState: Data?
    /// Set when this is a space's tab for a Favorite.
    var favoriteID: UUID?
    var groupID: UUID?
    /// The user took this tab out of a group, so automatic grouping leaves it alone.
    var noAutoGroup: Bool?
    /// The page's own description, and Apple Intelligence's note for the page at `noteURL`, for tab groups.
    var summary: String?
    var note: String?
    var noteURL: String?
}

nonisolated struct ClosedTabRecord: Codable, Equatable, Sendable {
    var tab: TabRecord
    var spaceID: UUID
    var index: Int
}

nonisolated struct WindowRecord: Codable, Equatable, Sendable {
    var spaceID: UUID
    var primaryTabID: UUID?
    var secondaryTabID: UUID?
    var splitRatio: Double = 0.5
    var frame: String?
    var sidebarCollapsed = false
}

nonisolated enum SessionCodec {
    static func encode(_ session: SessionRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(session)
    }

    static func decode(_ data: Data) throws -> SessionRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionRecord.self, from: data)
    }
}
