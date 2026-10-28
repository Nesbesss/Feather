import XCTest

final class TourProgressTests: XCTestCase {
    func testActionsDriveTheRealTour() {
        var tour = TourProgress()
        for (event, expected) in [(TourProgress.Event.began, TourProgress.Step.newTab),
                                 (.openedCommandBar, .address), (.submittedAddress, .favorite),
                                 (.addedFavorite, .spaces), (.createdSpace, .finished)] {
            tour.handle(event)
            XCTAssertEqual(tour.step, expected)
        }
    }

    func testCancelAddressLetsTheUserRetry() {
        var tour = TourProgress()
        tour.handle(.began)
        tour.handle(.openedCommandBar)
        tour.handle(.closedCommandBar)
        XCTAssertEqual(tour.step, .newTab)
        tour.handle(.openedCommandBar)
        XCTAssertEqual(tour.step, .address)
    }

    func testUnrelatedEventsCannotSkipPractice() {
        var tour = TourProgress()
        tour.handle(.createdSpace)
        XCTAssertEqual(tour.step, .intro)
        tour.handle(.began)
        tour.handle(.addedFavorite)
        XCTAssertEqual(tour.step, .newTab)
    }

    func testEveryStepIsSkippableAndBackDoesNotUndoUserData() {
        var tour = TourProgress()
        tour.handle(.began)
        for _ in 0..<8 { tour.handle(.next) }
        XCTAssertEqual(tour.step, .finished)
        tour.handle(.back)
        XCTAssertEqual(tour.step, .spaces)
        for _ in 0..<8 { tour.handle(.back) }
        XCTAssertEqual(tour.step, .newTab)
    }
}
