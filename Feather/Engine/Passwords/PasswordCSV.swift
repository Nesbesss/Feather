import Foundation

/// Reads password exports from Apple Passwords / Safari, Chrome, Firefox, and
/// Bitwarden. Columns are found by header name, so their order doesn't matter.
nonisolated enum PasswordCSV {
    struct Entry: Equatable, Sendable {
        var host: String
        var url: String
        var username: String
        var password: String
    }

    private static let urlColumns = ["url", "login_uri", "website", "origin", "web site"]
    private static let usernameColumns = ["username", "login_username", "user name", "login", "email"]
    private static let passwordColumns = ["password", "login_password"]

    /// Parsed logins, and how many rows were skipped for lacking a site or password.
    static func entries(from text: String) -> (entries: [Entry], skipped: Int) {
        var rows = parse(text)
        guard !rows.isEmpty else { return ([], 0) }
        let header = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let urlIndex = column(urlColumns), let passwordIndex = column(passwordColumns) else { return ([], rows.count) }
        let usernameIndex = column(usernameColumns)

        var entries: [Entry] = []
        var skipped = 0
        for row in rows where !(row.count == 1 && row[0].isEmpty) {
            func field(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Bitwarden can list several URIs; the first is the login's site.
            let url = field(urlIndex).split(separator: ",").first.map(String.init) ?? ""
            let password = field(passwordIndex)
            guard let host = host(of: url), !password.isEmpty else {
                skipped += 1
                continue
            }
            entries.append(Entry(host: host, url: url, username: field(usernameIndex), password: password))
        }
        return (entries, skipped)
    }

    static func host(of url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parsed = trimmed.contains("://") ? URL(string: trimmed) : URL(string: "https://" + trimmed)
        guard let host = parsed?.host(), !host.isEmpty else { return nil }
        return host.lowercased()
    }

    /// RFC 4180 fields: commas, quotes, doubled quotes, and line breaks inside quotes.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.drop(while: { $0 == "\u{FEFF}" }).makeIterator()
        var pending: Character? = nil
        while let char = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(char)
                }
                continue
            }
            switch char {
            case "\"": quoted = true
            case ",": row.append(field); field = ""
            case "\n", "\r\n", "\r":
                row.append(field); field = ""
                rows.append(row); row = []
            default: field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
