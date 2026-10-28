import AppKit
import UniformTypeIdentifiers

/// Whether Feather opens the links you click in other apps, and asking macOS to
/// make it so. macOS always confirms the change itself ("Use Feather" / "Keep Safari").
@MainActor @Observable
final class DefaultBrowser {
    static let shared = DefaultBrowser()

    private(set) var isDefault = false
    /// The app that opens web links now, when it isn't Feather.
    private(set) var currentName: String?

    private static let probe = URL(string: "https://example.com")!

    private init() {
        refresh()
        // The answer can change in System Settings while Feather runs.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { DefaultBrowser.shared.refresh() }
        }
    }

    func refresh() {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: Self.probe)
        isDefault = Self.isFeather(handler)
        currentName = isDefault ? nil : handler.map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.replacingOccurrences(of: ".app", with: "") }
    }

    private static func isFeather(_ app: URL?) -> Bool {
        app.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
    }

    /// Asks macOS to send http and https links (and .html files) to this copy of Feather.
    func makeDefault() {
        let app = Bundle.main.bundleURL
        let workspace = NSWorkspace.shared
        workspace.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            Task { @MainActor in
                defer { self.refresh() }
                guard error == nil else { return }
                // On recent macOS, http brings https and .html along; set them when it didn't.
                if !Self.isFeather(workspace.urlForApplication(toOpen: Self.probe)) {
                    try? await workspace.setDefaultApplication(at: app, toOpenURLsWithScheme: "https")
                }
                if !Self.isFeather(workspace.urlForApplication(toOpen: .html)) {
                    try? await workspace.setDefaultApplication(at: app, toOpen: .html)
                }
            }
        }
    }
}
