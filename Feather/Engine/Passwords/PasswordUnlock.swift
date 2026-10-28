import AppKit
import LocalAuthentication

/// Touch ID or the Mac's password before a saved password is used. One unlock
/// lasts 5 minutes and ends when the screen locks or sleeps.
final class PasswordUnlock {
    static let shared = PasswordUnlock()
    static let duration: TimeInterval = 5 * 60

    private var unlockedUntil: Date?

    init() {
        let lock: @Sendable (Notification) -> Void = { _ in Task { @MainActor in PasswordUnlock.shared.lock() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                                          object: nil, queue: .main, using: lock)
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"),
                                                            object: nil, queue: .main, using: lock)
    }

    var isUnlocked: Bool { unlockedUntil.map { $0 > Date() } ?? false }

    /// `reason` completes "Feather is trying to …".
    func unlock(reason: String) async -> Bool {
        if isUnlocked { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { return false }
            unlockedUntil = Date().addingTimeInterval(Self.duration)
            return true
        } catch {
            return false
        }
    }

    func lock() {
        unlockedUntil = nil
    }
}
