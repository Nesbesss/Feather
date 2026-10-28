import Foundation
import Security

struct SavedLogin: Identifiable, Hashable {
    var id: String { host + "\u{0}" + username }
    let host: String
    let username: String
    let isHTTPS: Bool
    let modified: Date?
}

/// Feather's passwords, stored as internet passwords in the login keychain.
/// Every item carries Feather's creator code and every query filters on it, so
/// Feather never reads other apps' keychain items.
final class PasswordStore {
    static let shared = PasswordStore()

    /// 'FTHR'
    static let creator: FourCharCode = 0x4654_4852

    private var cache: [SavedLogin]?

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassInternetPassword,
         kSecAttrCreator as String: NSNumber(value: Self.creator)]
    }

    func allLogins() -> [SavedLogin] {
        if let cache { return cache }
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let items = status == errSecSuccess ? (result as? [[String: Any]] ?? []) : []
        let logins = items.compactMap { item -> SavedLogin? in
            guard let host = item[kSecAttrServer as String] as? String else { return nil }
            let proto = item[kSecAttrProtocol as String] as? String
            return SavedLogin(host: host, username: item[kSecAttrAccount as String] as? String ?? "",
                              isHTTPS: proto != (kSecAttrProtocolHTTP as String),
                              modified: item[kSecAttrModificationDate as String] as? Date)
        }.sorted { ($0.host, $0.username) < ($1.host, $1.username) }
        cache = logins
        return logins
    }

    /// Logins for a page: exact host first, then the rest of the same site.
    func logins(forHost host: String) -> [SavedLogin] {
        allLogins()
            .compactMap { login in SiteMatcher.rank(savedHost: login.host, pageHost: host).map { (login, $0) } }
            .sorted { ($0.1, $0.0.username) < ($1.1, $1.0.username) }
            .map(\.0)
    }

    func login(host: String, username: String) -> SavedLogin? {
        allLogins().first { $0.host == host.lowercased() && $0.username == username }
    }

    /// The secret. Callers unlock with `PasswordUnlock` first.
    func password(for login: SavedLogin) -> String? {
        var query = itemQuery(host: login.host, username: login.username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Adds the login, or replaces the password of an existing one.
    @discardableResult
    func save(host: String, username: String, password: String, isHTTPS: Bool = true) -> Bool {
        let host = host.lowercased()
        let secret = Data(password.utf8)
        let existing = itemQuery(host: host, username: username)
        var status = SecItemUpdate(existing as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        if status == errSecItemNotFound {
            var item = existing
            item[kSecValueData as String] = secret
            item[kSecAttrProtocol as String] = isHTTPS ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP
            item[kSecAttrLabel as String] = "\(host) (Feather)"
            item[kSecAttrDescription as String] = "Feather web password"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        cache = nil
        return status == errSecSuccess
    }

    func delete(_ login: SavedLogin) {
        SecItemDelete(itemQuery(host: login.host, username: login.username) as CFDictionary)
        cache = nil
    }

    private func itemQuery(host: String, username: String) -> [String: Any] {
        var query = baseQuery
        query[kSecAttrServer as String] = host
        query[kSecAttrAccount as String] = username
        return query
    }
}
