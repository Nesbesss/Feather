import XCTest

final class FavoriteSuggestionsTests: XCTestCase {
    func testMostVisitedFirstWithoutWWWDuplicatesOrExistingFavorites() {
        let visits = ["www.github.com": 5, "github.com": 4, "news.ycombinator.com": 12, "www.youtube.com": 3]
        let hosts = FavoriteSuggestions.suggestions(visits: visits, existing: ["youtube.com"]).map(\.host)
        // github.com's two spellings add up (9) and still rank below Hacker News (12); starters fill the rest.
        XCTAssertEqual(hosts, ["news.ycombinator.com", "github.com", "mail.google.com", "wikipedia.org"])
    }

    func testStartersWhenThereIsNoHistory() {
        let sites = FavoriteSuggestions.suggestions(visits: [:], existing: [])
        XCTAssertEqual(sites.map(\.host), FavoriteSuggestions.starters)
        XCTAssertEqual(sites.first?.url.absoluteString, "https://youtube.com/")
    }

    func testSavedPageIgnoresFragmentWWWAndTrailingSlash() {
        let key = { (string: String) in FavoriteSuggestions.pageKey(URL(string: string)!) }
        XCTAssertEqual(key("https://www.youtube.com/"), key("https://youtube.com"))
        XCTAssertEqual(key("https://mail.google.com/mail/u/0/#inbox"), key("https://mail.google.com/mail/u/0/"))
        XCTAssertNotEqual(key("https://youtube.com/"), key("https://youtube.com/watch?v=abc"))
    }
}

final class FavoritesSessionTests: XCTestCase {
    func testFavoritesAndTheirTabsRoundTrip() throws {
        let favorite = FavoriteRecord(id: UUID(), url: "https://youtube.com/", title: "YouTube")
        let tab = TabRecord(id: UUID(), url: "https://www.youtube.com/watch?v=abc", title: "A video",
                            lastActive: Date(timeIntervalSince1970: 1_700_000_000), interactionState: nil,
                            favoriteID: favorite.id)
        let space = SpaceRecord(id: UUID(), name: "Home", hue: 0.6, dataStoreID: nil, pinned: [], tabs: [],
                                lastSelectedTabID: tab.id, favoriteTabs: [tab])
        let session = SessionRecord(spaces: [space], windows: [], favorites: [favorite])
        XCTAssertEqual(try SessionCodec.decode(SessionCodec.encode(session)), session)
    }

    func testOlderSessionFilesWithoutFavoritesStillLoad() throws {
        let json = """
        {"version":1,"spaces":[{"id":"\(UUID().uuidString)","name":"Home","hue":0.6,"pinned":[],"tabs":[]}],
         "windows":[],"recentlyClosed":[]}
        """
        let session = try SessionCodec.decode(Data(json.utf8))
        XCTAssertNil(session.favorites)
        XCTAssertNil(session.spaces[0].favoriteTabs)
    }
}
