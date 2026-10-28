import XCTest

final class FirstRunPolicyTests: XCTestCase {
    func testFreshInstallWelcomesUser() {
        XCTAssertTrue(decision())
    }

    func testExistingSessionIsNotInterruptedOnUpgrade() {
        XCTAssertFalse(decision(saved: true))
    }

    func testCompletionSurvivesAnEmptyOrDeletedSession() {
        XCTAssertFalse(decision(completed: FirstRunPolicy.currentVersion))
    }

    func testNewerCompletionIsNotDowngraded() {
        XCTAssertFalse(decision(completed: FirstRunPolicy.currentVersion + 1))
    }

    func testUnfinishedFirstRunResumesAfterHomeSessionWasSaved() {
        XCTAssertTrue(FirstRunPolicy.shouldPresent(completedVersion: 0, hasSavedSession: true,
                                                  isAutomated: false, previewRequested: false,
                                                  hasStartedWelcome: true))
        XCTAssertFalse(FirstRunPolicy.shouldPresent(completedVersion: FirstRunPolicy.currentVersion,
                                                   hasSavedSession: true, isAutomated: false,
                                                   previewRequested: false, hasStartedWelcome: true))
    }

    func testExplicitPreviewCanReplayWithoutResettingProfile() {
        XCTAssertTrue(decision(completed: FirstRunPolicy.currentVersion, saved: true, preview: true))
    }

    func testAutomatedRunsNeverWaitForGuide() {
        for saved in [false, true] {
            for preview in [false, true] {
                XCTAssertFalse(decision(saved: saved, automated: true, preview: preview))
            }
        }
    }

    private func decision(completed: Int = 0, saved: Bool = false,
                          automated: Bool = false, preview: Bool = false) -> Bool {
        FirstRunPolicy.shouldPresent(completedVersion: completed, hasSavedSession: saved,
                                     isAutomated: automated, previewRequested: preview)
    }
}
