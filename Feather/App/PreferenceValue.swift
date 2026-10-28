import Foundation

/// UserDefaults argument-domain booleans are strings; bool(forKey:) handles
/// both those overrides and stored Bool values without changing preferences.
nonisolated enum PreferenceValue {
    static func bool(forKey key: String, in defaults: UserDefaults, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}
