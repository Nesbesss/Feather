import Foundation

/// Launch-time decisions are independent of the UI, so a benchmark cannot get
/// stuck behind a welcome and an existing profile never looks like a new install.
nonisolated enum FirstRunPolicy {
    static let completedKey = "FeatherWelcomeCompletedVersion"
    static let startedKey = "FeatherWelcomeStarted"
    static let currentVersion = 1

    static func shouldPresent(completedVersion: Int, hasSavedSession: Bool,
                              isAutomated: Bool, previewRequested: Bool,
                              hasStartedWelcome: Bool = false) -> Bool {
        guard !isAutomated else { return false }
        if previewRequested { return true }
        return completedVersion < currentVersion && (!hasSavedSession || hasStartedWelcome)
    }
}
