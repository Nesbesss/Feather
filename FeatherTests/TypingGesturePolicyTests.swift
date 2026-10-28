import XCTest

final class TypingGesturePolicyTests: XCTestCase {
    func testPrintableCharactersSpacesAndInternationalTextAreAccepted() {
        for text in ["a", "A", "7", "!", " ", "é", "日", "🪶"] {
            XCTAssertTrue(accepts(text))
        }
    }

    func testBackspaceAndForwardDeleteDoNotNeedCharacters() {
        XCTAssertTrue(accepts(nil, keyCode: 51))
        XCTAssertTrue(accepts("", keyCode: 117))
    }

    func testNoSoundForMissingOrEmptyCharacters() {
        XCTAssertFalse(accepts(nil))
        XCTAssertFalse(accepts(""))
    }

    func testShortcutsAreExcludedEvenForDeleteAndPrintableInput() {
        XCTAssertFalse(accepts("a", command: true))
        XCTAssertFalse(accepts("a", control: true))
        XCTAssertFalse(accepts("é", option: true))
        XCTAssertFalse(accepts(nil, keyCode: 51, command: true))
        XCTAssertFalse(accepts(nil, keyCode: 117, option: true))
    }

    func testNavigationFunctionAndModifierKeysNeverPlay() {
        let keyCodes: [UInt16] = [36, 48, 53, 55, 56, 57, 58, 59, 63, 71, 76,
                                  114, 115, 116, 119, 121, 123, 124, 125, 126,
                                  122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                                  103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for keyCode in keyCodes {
            XCTAssertFalse(accepts("a", keyCode: keyCode))
        }
    }

    func testControlAndAppKitFunctionCharactersAreExcluded() {
        for text in ["\n", "\r", "\t", "\u{1B}", "\u{F700}", "\u{F70A}", "\u{200B}", "\u{2028}"] {
            XCTAssertFalse(accepts(text))
        }
    }

    private func accepts(_ text: String?, keyCode: UInt16 = 0, command: Bool = false,
                         control: Bool = false, option: Bool = false) -> Bool {
        TypingGesturePolicy.shouldPlay(keyCode: keyCode, characters: text,
                                       command: command, control: control, option: option)
    }
}
