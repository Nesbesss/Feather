import XCTest
import SQLite3

final class HistoryStoreTests: XCTestCase {
    func testRepeatedQueriesUseFreshParametersAndSeeNewVisits() throws {
        try withStore { store in
            let space = UUID()
            let first = URL(string: "https://alpha.example/project")!
            let second = URL(string: "https://beta.example/project")!
            store.record(first, title: "Alpha project", space: space)
            store.record(second, title: "Beta project", space: space)
            store.record(second, title: "", space: space)

            XCTAssertEqual(store.search("project", space: space, limit: 1).map(\.url), [second])
            XCTAssertEqual(store.search("alpha", space: space, limit: 6).map(\.url), [first])
            XCTAssertEqual(store.search("beta", space: space, limit: 6).first?.title, "Beta project")

            store.record(first, title: "Alpha project", space: space)
            store.record(first, title: "Alpha project", space: space)
            XCTAssertEqual(store.search("project", space: space, limit: 1).map(\.url), [first])

            store.updateTitle("Renamed", for: second, space: space)
            XCTAssertEqual(store.search("renamed", space: space, limit: 6).map(\.url), [second])
            XCTAssertEqual(store.hosts(withPrefix: "al", space: space).first?.score, 3)
            XCTAssertEqual(store.hosts(withPrefix: "be", space: space).first?.host, "beta.example")

            store.clear(space: space)
            XCTAssertTrue(store.search("project", space: space, limit: 6).isEmpty)
            XCTAssertTrue(store.hosts(withPrefix: "al", space: space).isEmpty)
            XCTAssertTrue(store.visitsByHost().isEmpty)
        }
    }

    func testQueriesStayWithinTheirSpace() throws {
        try withStore { store in
            let home = UUID()
            let work = UUID()
            let homeURL = URL(string: "https://home.example/")!
            let workURL = URL(string: "https://work.example/")!
            store.record(homeURL, title: "Home", space: home)
            store.record(workURL, title: "Work", space: work)

            XCTAssertEqual(store.search("", space: home, limit: 10).map(\.url), [homeURL])
            XCTAssertEqual(store.search("", space: work, limit: 10).map(\.url), [workURL])
            store.clear(space: home)
            XCTAssertEqual(store.search("", space: work, limit: 10).map(\.url), [workURL])
        }
    }

    func testOpeningExistingDatabasePreservesHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite")
        let space = UUID()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let sql = """
            CREATE TABLE history (space TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL,
                visits INTEGER NOT NULL, last REAL NOT NULL, PRIMARY KEY (space, url));
            INSERT INTO history VALUES ('\(space.uuidString)', 'https://existing.example/', 'Existing page', 4, 1);
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = try XCTUnwrap(HistoryStore(url: url))
        XCTAssertEqual(store.search("existing", space: space, limit: 6).first?.title, "Existing page")
        store.record(URL(string: "https://existing.example/")!, title: "Updated page", space: space)
        XCTAssertEqual(store.hosts(withPrefix: "existing", space: space).first?.score, 5)
    }

    func testAutocompleteUsesVisitedHostRatherThanEmbeddedAddress() throws {
        try withStore { store in
            let space = UUID()
            let proxy = URL(string: "https://proxy.example/cache/https://github.com/project")!
            for _ in 0..<5 { store.record(proxy, title: "Proxy", space: space) }
            store.record(URL(string: "https://github.com/project")!, title: "GitHub", space: space)
            XCTAssertEqual(store.hosts(withPrefix: "gith", space: space, limit: 1).map(\.host), ["github.com"])
        }
    }

    func testAutocompletePreservesWWWCaseAndLiteralWildcardCharacters() throws {
        try withStore { store in
            let space = UUID()
            let wiki = URL(string: "https://www.wikipedia.org/")!
            for _ in 0..<3 { store.record(wiki, title: "Wikipedia", space: space) }
            store.record(URL(string: "http://www.wikipedia.org/legacy")!, title: "Legacy", space: space)
            store.record(URL(string: "https://under_score.example/")!, title: "Literal", space: space)
            store.record(URL(string: "https://underXscore.example/")!, title: "Other", space: space)
            XCTAssertEqual(store.hosts(withPrefix: "w", space: space).first { $0.host == "www.wikipedia.org" }?.score, 4)
            XCTAssertEqual(store.hosts(withPrefix: "WIKI", space: space).first?.score, 4)
            XCTAssertEqual(store.hosts(withPrefix: "under_", space: space).map(\.host), ["under_score.example"])
            XCTAssertTrue(store.hosts(withPrefix: "under%", space: space).isEmpty)
            XCTAssertTrue(store.hosts(withPrefix: "under\\", space: space).isEmpty)
        }
    }

    func testAutocompleteFindsRareHostsBeyondRankedLookahead() throws {
        try withStore { store in
            let space = UUID()
            for i in 0..<72 {
                let url = URL(string: "https://popular\(i).example/")!
                store.record(url, title: "Popular", space: space)
                store.record(url, title: "Popular", space: space)
            }
            store.record(URL(string: "https://rare.example/project")!, title: "Rare", space: space)
            let candidates = store.hosts(withPrefix: "rare", space: space, limit: 1)
            XCTAssertEqual(candidates.map(\.host), ["rare.example"])
            XCTAssertEqual(candidates.first?.score, 1)
        }
    }

    func testReadonlyLegacyHistoryStillCompletesWhenIndexCannotBeCreated() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("history.sqlite")
        let space = UUID()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: folder)
        }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE history (space TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL,
                visits INTEGER NOT NULL, last REAL NOT NULL, PRIMARY KEY (space, url));
            INSERT INTO history VALUES ('\(space.uuidString)', 'https://readonly.example/', 'Read only', 4, 1);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        let store = try XCTUnwrap(HistoryStore(url: url))
        XCTAssertEqual(store.search("readonly", space: space, limit: 6).first?.title, "Read only")
        XCTAssertEqual(store.hosts(withPrefix: "read", space: space).first?.host, "readonly.example")
    }

    private func withStore(_ body: (HistoryStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var store = HistoryStore(url: folder.appendingPathComponent("history.sqlite"))
        defer {
            store = nil
            try? FileManager.default.removeItem(at: folder)
        }
        try body(XCTUnwrap(store))
    }
}
