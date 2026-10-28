import Foundation

/// Arc-style cleanup: unpinned tabs nobody has looked at for a while move out
/// of the sidebar into the space's archive, where the command bar still finds them.
nonisolated enum ArchivePolicy {
    struct Facts: Sendable {
        var id: UUID
        var lastActive: Date
        var isPinned = false
        var isVisible = false
        var isPlayingAudio = false
        var hasUnsavedInput = false
    }

    /// Kept per space, newest first.
    static let maxArchived = 500
    /// How many of those keep their back/forward history; older ones keep only URL and title,
    /// so the session file stays small.
    static let maxWithHistory = 20

    static func tabsToArchive(_ tabs: [Facts], now: Date, after interval: TimeInterval) -> [UUID] {
        guard interval.isFinite, interval > 0 else { return [] }
        return tabs.filter { tab in
            !tab.isPinned && !tab.isVisible && !tab.isPlayingAudio && !tab.hasUnsavedInput
                && now.timeIntervalSince(tab.lastActive) >= interval
        }.map(\.id)
    }
}
