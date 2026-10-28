import Foundation
import SQLite3

/// Visited pages per space, used for command-bar suggestions. Capped so the
/// file and its queries stay small.
final class HistoryStore {
    struct Entry {
        var url: URL
        var title: String
    }

    static let maxRows = 20_000

    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var insertsSincePrune = 0
    private var hasPrefixIndex = false
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL) {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return nil }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA cache_size=-2048")
        exec("""
            CREATE TABLE IF NOT EXISTS history (
                space TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL,
                visits INTEGER NOT NULL, last REAL NOT NULL, PRIMARY KEY (space, url))
            """)
        exec("CREATE INDEX IF NOT EXISTS history_last ON history (last)")
        hasPrefixIndex = exec("CREATE INDEX IF NOT EXISTS history_url_prefix ON history (space, url COLLATE NOCASE, visits DESC, last DESC)")
        // Suggestions run on every keystroke. Keep their ranking and selected
        // columns in one index, so SQLite can stop at LIMIT without sorting the
        // entire space or fetching each matching row from the table.
        exec("CREATE INDEX IF NOT EXISTS history_ranked ON history (space, visits DESC, last DESC, url, title)")
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    func record(_ url: URL, title: String, space: UUID) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        run("""
            INSERT INTO history (space, url, title, visits, last) VALUES (?, ?, ?, 1, ?)
            ON CONFLICT (space, url) DO UPDATE SET visits = visits + 1, last = excluded.last,
                title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE title END
            """, [space.uuidString, url.absoluteString, title, Date().timeIntervalSince1970])
        insertsSincePrune += 1
        if insertsSincePrune >= 500 {
            insertsSincePrune = 0
            run("DELETE FROM history WHERE rowid IN (SELECT rowid FROM history ORDER BY last DESC LIMIT -1 OFFSET ?)",
                [Self.maxRows])
        }
    }

    func updateTitle(_ title: String, for url: URL, space: UUID) {
        run("UPDATE history SET title = ? WHERE space = ? AND url = ?", [title, space.uuidString, url.absoluteString])
    }

    func search(_ text: String, space: UUID, limit: Int) -> [Entry] {
        let pattern = "%" + text.replacingOccurrences(of: "%", with: "") + "%"
        var entries: [Entry] = []
        query("""
            SELECT url, title FROM history WHERE space = ? AND (url LIKE ? OR title LIKE ?)
            ORDER BY visits DESC, last DESC LIMIT ?
            """, [space.uuidString, pattern, pattern, limit]) { statement in
            if let url = URL(string: String(cString: sqlite3_column_text(statement, 0))) {
                entries.append(Entry(url: url, title: String(cString: sqlite3_column_text(statement, 1))))
            }
        }
        return entries
    }

    /// Visits per host for hosts starting with `prefix` (with or without "www."), for inline completion.
    func hosts(withPrefix prefix: String, space: UUID, limit: Int = 300) -> [Autocomplete.Candidate] {
        let escaped = prefix.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let patterns = ["https://" + escaped + "%", "http://" + escaped + "%",
                        "https://www." + escaped + "%", "http://www." + escaped + "%"]
        var pages: [(url: String, visits: Double)] = []
        // A read-only or full disk may prevent a one-time index migration.
        // Existing history must remain usable through the original query.
        if !hasPrefixIndex {
            query("""
                SELECT url, visits FROM history WHERE space = ? AND (url LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\')
                ORDER BY visits DESC LIMIT ?
                """, [space.uuidString, "%://" + escaped + "%", "%://www." + escaped + "%", limit]) { statement in
                pages.append((String(cString: sqlite3_column_text(statement, 0)), Double(sqlite3_column_int64(statement, 1))))
            }
        }
        if hasPrefixIndex && limit > 0 && limit <= 1_024 {
            // Broad prefixes normally have enough matches near the top. Stop
            // after a bounded ranked prefix rather than sorting thousands.
            query("""
                SELECT url, visits FROM (
                    SELECT url, visits, last FROM history INDEXED BY history_ranked WHERE space = ?
                    ORDER BY visits DESC, last DESC, url LIMIT ?
                ) WHERE url LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\'
                ORDER BY visits DESC, last DESC, url LIMIT ?
                """, [space.uuidString, max(64, limit * 2), patterns[0], patterns[1], patterns[2], patterns[3], limit]) { statement in
                pages.append((String(cString: sqlite3_column_text(statement, 0)), Double(sqlite3_column_int64(statement, 1))))
            }
        }
        if hasPrefixIndex && (pages.count < limit || limit < 0) {
            pages.removeAll(keepingCapacity: true)
            query("""
                SELECT url, visits FROM (
                    SELECT url, visits, last FROM history INDEXED BY history_url_prefix WHERE space = ? AND url LIKE ? ESCAPE '\\'
                    UNION ALL
                    SELECT url, visits, last FROM history INDEXED BY history_url_prefix WHERE space = ? AND url LIKE ? ESCAPE '\\'
                    UNION ALL
                    SELECT url, visits, last FROM history INDEXED BY history_url_prefix WHERE space = ? AND url LIKE ? ESCAPE '\\' AND url NOT LIKE ? ESCAPE '\\'
                    UNION ALL
                    SELECT url, visits, last FROM history INDEXED BY history_url_prefix WHERE space = ? AND url LIKE ? ESCAPE '\\' AND url NOT LIKE ? ESCAPE '\\'
                ) ORDER BY visits DESC, last DESC, url LIMIT ?
                """, [space.uuidString, patterns[0], space.uuidString, patterns[1],
                      space.uuidString, patterns[2], patterns[0], space.uuidString, patterns[3], patterns[1], limit]) { statement in
                pages.append((String(cString: sqlite3_column_text(statement, 0)), Double(sqlite3_column_int64(statement, 1))))
            }
        }
        var visits: [String: Double] = [:]
        for page in pages {
            if let host = URL(string: page.url)?.host() { visits[host, default: 0] += page.visits }
        }
        return visits.map { Autocomplete.Candidate(host: $0.key, score: $0.value) }
    }

    /// Visits per host across every space, from the most visited pages; for Favorites suggestions.
    func visitsByHost(pages: Int = 500) -> [String: Int] {
        var visits: [String: Int] = [:]
        query("SELECT url, visits FROM history WHERE url LIKE 'http%' ORDER BY visits DESC LIMIT ?", [pages]) { statement in
            if let url = URL(string: String(cString: sqlite3_column_text(statement, 0))), let host = url.host() {
                visits[host, default: 0] += Int(sqlite3_column_int64(statement, 1))
            }
        }
        return visits
    }

    func clear(space: UUID) {
        run("DELETE FROM history WHERE space = ?", [space.uuidString])
    }

    // MARK: SQLite helpers

    @discardableResult private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func run(_ sql: String, _ values: [Any]) {
        query(sql, values) { _ in }
    }

    private func query(_ sql: String, _ values: [Any], row: (OpaquePointer) -> Void) {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil) == SQLITE_OK,
                  let prepared else { return }
            statements[sql] = prepared
            statement = prepared
        }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, index, text, -1, transient)
            case let number as Double: sqlite3_bind_double(statement, index, number)
            case let number as Int: sqlite3_bind_int64(statement, index, Int64(number))
            default: sqlite3_bind_null(statement, index)
            }
        }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }
}
