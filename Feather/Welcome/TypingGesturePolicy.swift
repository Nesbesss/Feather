import Foundation

/// Decides whether a key-down represents text entry without keeping its text.
/// The caller owns app/window activity and the user's sound-scope preference.
nonisolated enum TypingGesturePolicy {
    private static let nonTypingKeys: Set<UInt16> = [
        36, 48, 53,                       // Return, Tab, Escape
        54, 55, 56, 57, 58, 59, 60, 61, 62, 63, // Modifier keys
        71, 76,                          // Keypad Clear and Enter
        114, 115, 116, 119, 121, 123, 124, 125, 126, // Help/navigation
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, // F1–F10
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90, // F11–F20
    ]

    static func shouldPlay(keyCode: UInt16, characters: String?,
                           command: Bool, control: Bool, option: Bool) -> Bool {
        guard !command, !control, !option else { return false }
        if keyCode == 51 || keyCode == 117 { return true } // Backspace/forward delete
        guard !nonTypingKeys.contains(keyCode), let characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.contains { scalar in
            // AppKit encodes function/navigation keys in this private-use range.
            guard !(0xF700...0xF8FF).contains(scalar.value) else { return false }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .unassigned, .lineSeparator, .paragraphSeparator:
                return false
            default:
                return true
            }
        }
    }
}
