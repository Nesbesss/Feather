import Foundation

/// Saved click-sound preference. An absent or unrecognized value keeps the
/// quiet default: clicks belong to the tour until the user chooses otherwise.
nonisolated enum ClickSoundScope: String, CaseIterable, Identifiable, Sendable {
    case off, tour, everywhere

    static let defaultValue: Self = .tour
    var id: String { rawValue }

    init(preferenceValue: String?) {
        self = preferenceValue.flatMap(Self.init(rawValue:)) ?? Self.defaultValue
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .tour: "Tour only"
        case .everywhere: "Everywhere in Feather"
        }
    }
}

/// Recognizes a completed click without depending on AppKit. The event owner
/// supplies Feather window numbers and cancels when its app loses activity.
nonisolated struct ClickGesturePolicy: Sendable {
    static let maximumDistance = 5.0
    private var down: (windowNumber: Int, x: Double, y: Double)?

    mutating func mouseDown(windowNumber: Int, x: Double, y: Double) {
        down = nil
        guard windowNumber > 0, x.isFinite, y.isFinite else { return }
        down = (windowNumber, x, y)
    }

    /// Any drag event cancels the candidate, even if it ends near its origin.
    mutating func mouseDragged() { down = nil }

    mutating func mouseUp(windowNumber: Int, x: Double, y: Double) -> Bool {
        defer { down = nil }
        guard let down, windowNumber == down.windowNumber,
              x.isFinite, y.isFinite else { return false }
        let dx = x - down.x
        let dy = y - down.y
        return dx * dx + dy * dy <= Self.maximumDistance * Self.maximumDistance
    }

    mutating func cancel() { down = nil }
}
