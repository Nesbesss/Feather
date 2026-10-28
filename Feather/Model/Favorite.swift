import Foundation

/// A site in the sidebar's Favorites grid: the few sites you open every day.
/// Favorites are shared by every space. Each space opens its own tab for one,
/// with that space's cookies and logins, and the tab can always go back to the
/// favorite's saved page.
@Observable
final class Favorite: Identifiable {
    let id: UUID
    var url: URL
    var title: String

    init(id: UUID = UUID(), url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }

    convenience init?(record: FavoriteRecord) {
        guard let url = URL(string: record.url) else { return nil }
        self.init(id: record.id, url: url, title: record.title)
    }

    var host: String { url.host().map(Autocomplete.stripWWW) ?? url.absoluteString }

    var displayTitle: String { title.isEmpty ? host : title }

    func record() -> FavoriteRecord {
        FavoriteRecord(id: id, url: url.absoluteString, title: title)
    }

    /// Whether `url` is still on the favorite's saved page (ignoring the fragment and a trailing slash).
    func isAtSavedPage(_ url: URL?) -> Bool {
        guard let url else { return true }
        return FavoriteSuggestions.pageKey(url) == FavoriteSuggestions.pageKey(self.url)
    }
}
