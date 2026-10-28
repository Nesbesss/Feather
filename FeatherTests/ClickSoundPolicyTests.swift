import XCTest

final class ClickSoundScopeTests: XCTestCase {
    func testMissingOrUnknownPreferencesDefaultToTour() {
        XCTAssertEqual(ClickSoundScope(preferenceValue: nil), .tour)
        XCTAssertEqual(ClickSoundScope(preferenceValue: ""), .tour)
        XCTAssertEqual(ClickSoundScope(preferenceValue: "unknown"), .tour)
    }

    func testEverySavedModeRoundTripsWithStableIdentifierAndTitle() {
        XCTAssertEqual(ClickSoundScope.allCases.map(\.title), ["Off", "Tour only", "Everywhere in Feather"])
        for scope in ClickSoundScope.allCases {
            XCTAssertEqual(ClickSoundScope(preferenceValue: scope.rawValue), scope)
            XCTAssertEqual(scope.id, scope.rawValue)
        }
    }
}

final class ClickGesturePolicyTests: XCTestCase {
    func testFivePointEuclideanBoundaryIsAccepted() {
        var gesture = ClickGesturePolicy()
        gesture.mouseDown(windowNumber: 3, x: 100, y: 100)
        XCTAssertTrue(gesture.mouseUp(windowNumber: 3, x: 103, y: 104))
        gesture.mouseDown(windowNumber: 3, x: 100, y: 100)
        XCTAssertFalse(gesture.mouseUp(windowNumber: 3, x: 104, y: 104))
    }

    func testMouseUpMustMatchTheWindowAndAlwaysClears() {
        var gesture = ClickGesturePolicy()
        gesture.mouseDown(windowNumber: 3, x: 20, y: 20)
        XCTAssertFalse(gesture.mouseUp(windowNumber: 4, x: 20, y: 20))
        XCTAssertFalse(gesture.mouseUp(windowNumber: 3, x: 20, y: 20))
        gesture.mouseDown(windowNumber: 3, x: 20, y: 20)
        XCTAssertTrue(gesture.mouseUp(windowNumber: 3, x: 20, y: 20))
        XCTAssertFalse(gesture.mouseUp(windowNumber: 3, x: 20, y: 20))
    }

    func testEvenAShortDragCancelsItsClick() {
        var gesture = ClickGesturePolicy()
        gesture.mouseDown(windowNumber: 3, x: 20, y: 20)
        gesture.mouseDragged()
        XCTAssertFalse(gesture.mouseUp(windowNumber: 3, x: 21, y: 20))
        gesture.mouseDown(windowNumber: 3, x: 20, y: 20)
        XCTAssertTrue(gesture.mouseUp(windowNumber: 3, x: 20, y: 20))
    }

    func testCancelAndLargeMovementClearThePendingClick() {
        var gesture = ClickGesturePolicy()
        gesture.mouseDown(windowNumber: 3, x: 20, y: 20)
        gesture.cancel()
        XCTAssertFalse(gesture.mouseUp(windowNumber: 3, x: 20, y: 20))
        gesture.mouseDown(windowNumber: 3, x: 20, y: 20)
        XCTAssertFalse(gesture.mouseUp(windowNumber: 3, x: 40, y: 20))
        XCTAssertFalse(gesture.mouseUp(windowNumber: 3, x: 20, y: 20))
    }

    func testInvalidCoordinatesOrWindowCannotReuseAnEarlierDown() {
        var gesture = ClickGesturePolicy()
        gesture.mouseDown(windowNumber: 3, x: 20, y: 20)
        gesture.mouseDown(windowNumber: 0, x: 20, y: 20)
        XCTAssertFalse(gesture.mouseUp(windowNumber: 3, x: 20, y: 20))
        gesture.mouseDown(windowNumber: 3, x: .nan, y: 20)
        XCTAssertFalse(gesture.mouseUp(windowNumber: 3, x: 20, y: 20))
        gesture.mouseDown(windowNumber: 3, x: 20, y: 20)
        XCTAssertFalse(gesture.mouseUp(windowNumber: 3, x: .infinity, y: 20))
        XCTAssertFalse(gesture.mouseUp(windowNumber: 3, x: 20, y: 20))
    }

    func testMostRecentDownReplacesTheEarlierWindow() {
        var gesture = ClickGesturePolicy()
        gesture.mouseDown(windowNumber: 3, x: 20, y: 20)
        gesture.mouseDown(windowNumber: 4, x: 40, y: 40)
        XCTAssertTrue(gesture.mouseUp(windowNumber: 4, x: 40, y: 40))
    }
}

final class WelcomeClickHandlerTests: XCTestCase {
    func testSharedHandlerRunsOnceOnlyWhenLiveAndUnmuted() {
        MainActor.assumeIsolated {
            let playback = WelcomePlaybackState(sound: WelcomeSound(resourceURL: nil))
            var calls = 0
            playback.clickHandler = { calls += 1; return true }
            XCTAssertFalse(playback.playClick())
            playback.isMuted = true
            playback.live = true
            XCTAssertFalse(playback.playClick())
            XCTAssertEqual(calls, 0)
            playback.isMuted = false
            XCTAssertTrue(playback.playClick())
            XCTAssertEqual(calls, 1)
            playback.clickHandler = { calls += 1; return false }
            XCTAssertFalse(playback.playClick())
            XCTAssertEqual(calls, 2)
            XCTAssertFalse(playback.sound.isClickPlaying)
            playback.live = false
            XCTAssertFalse(playback.playClick())
            XCTAssertEqual(calls, 2)
        }
    }
}
