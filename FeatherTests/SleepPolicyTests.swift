import XCTest

final class SleepPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func tab(_ minutesAgo: Double, live: Bool = true, visible: Bool = false) -> TabFacts {
        TabFacts(id: UUID(), isLive: live, isVisible: visible, lastActive: now.addingTimeInterval(-minutesAgo * 60))
    }

    func testIdleBackgroundTabSleeps() {
        let old = tab(6), fresh = tab(1)
        let decisions = SleepPolicy.lean.tabsToSleep([old, fresh], now: now)
        XCTAssertEqual(decisions, [SleepDecision(id: old.id, reason: .idle)])
    }

    func testVisibleTabNeverSleeps() {
        let visible = tab(600, visible: true)
        XCTAssertTrue(SleepPolicy.lean.tabsToSleep([visible], now: now, pressure: .critical).isEmpty)
    }

    func testMediaCaptureAndUnsavedInputAreExempt() {
        var audio = tab(60), camera = tab(60), form = tab(60)
        audio.isPlayingMedia = true
        camera.isCapturingMedia = true
        form.hasUnsavedInput = true
        XCTAssertTrue(SleepPolicy.lean.tabsToSleep([audio, camera, form], now: now).isEmpty)
    }

    func testOverBudgetEvictsLeastRecentlyUsedFirst() {
        let policy = SleepPolicy(maxLiveTabs: 2, sleepAfter: .infinity, hiddenSpaceSleepAfter: .infinity, footprintLimit: nil)
        let visible = tab(0, visible: true), a = tab(3), b = tab(2), c = tab(1)
        let decisions = policy.tabsToSleep([visible, c, a, b], now: now)
        XCTAssertEqual(decisions, [SleepDecision(id: a.id, reason: .overBudget), SleepDecision(id: b.id, reason: .overBudget)])
    }

    func testExemptTabsCountTowardBudget() {
        let policy = SleepPolicy(maxLiveTabs: 2, sleepAfter: .infinity, hiddenSpaceSleepAfter: .infinity, footprintLimit: nil)
        var audio = tab(10)
        audio.isPlayingMedia = true
        let visible = tab(0, visible: true), other = tab(5)
        XCTAssertEqual(policy.tabsToSleep([visible, audio, other], now: now).map(\.id), [other.id])
    }

    func testHiddenSpaceSleepsSooner() {
        var hidden = tab(2)
        hidden.inVisibleSpace = false
        let shown = tab(2)
        XCTAssertEqual(SleepPolicy.lean.tabsToSleep([hidden, shown], now: now).map(\.id), [hidden.id])
    }

    func testFootprintLimit() {
        var heavy = tab(2)
        heavy.footprint = 2_000_000_000
        XCTAssertEqual(SleepPolicy.lean.tabsToSleep([heavy], now: now), [SleepDecision(id: heavy.id, reason: .footprint)])
    }

    func testMemoryPressureSleepsEveryEligibleTab() {
        let visible = tab(0, visible: true), a = tab(2), b = tab(3)
        let decisions = SleepPolicy.balanced.tabsToSleep([visible, a, b], now: now, pressure: .warning)
        XCTAssertEqual(Set(decisions.map(\.id)), [a.id, b.id])
        XCTAssertTrue(decisions.allSatisfy { $0.reason == .memoryPressure })
    }

    func testNeverPolicyKeepsEverything() {
        XCTAssertTrue(SleepPolicy.never.tabsToSleep([tab(10_000), tab(20_000)], now: now).isEmpty)
        XCTAssertTrue(SleepPolicy.never.tabsToSleep([tab(10_000)], now: now, pressure: .critical).isEmpty)
    }

    func testUnloadedTabsAreIgnored() {
        XCTAssertTrue(SleepPolicy.lean.tabsToSleep([tab(60, live: false)], now: now).isEmpty)
    }

    func testRecentTabsSurviveBudgetFootprintIdleAndWarningPressure() {
        var recent = tab(0.5)
        recent.footprint = 9_000_000_000
        recent.inVisibleSpace = false
        var policy = SleepPolicy.lean
        policy.maxLiveTabs = 1
        policy.hiddenSpaceSleepAfter = 1
        let tabs = [tab(0, visible: true), recent]
        XCTAssertTrue(policy.tabsToSleep(tabs, now: now).isEmpty)
        XCTAssertTrue(policy.tabsToSleep(tabs, now: now, pressure: .warning).isEmpty)
        XCTAssertEqual(policy.tabsToSleep(tabs, now: now, pressure: .critical).map(\.id), [recent.id])
    }

    func testGracePeriodEndsAtBoundaryAndBudgetRemainsLRU() {
        var policy = SleepPolicy.lean
        policy.maxLiveTabs = 1
        let eligible = tab(1), recent = tab(0.99)
        XCTAssertEqual(policy.tabsToSleep([recent, eligible], now: now).map(\.id), [eligible.id])
    }

    func testLoadingAndAuthenticationPopupsAreProtectedEvenUnderCriticalPressure() {
        var loading = tab(60), popup = tab(60), form = tab(60), audio = tab(60), capture = tab(60)
        loading.isLoading = true
        popup.hasActivePopup = true
        form.hasUnsavedInput = true
        audio.isPlayingMedia = true
        capture.isCapturingMedia = true
        XCTAssertTrue(SleepPolicy.lean.tabsToSleep([loading, popup, form, audio, capture], now: now, pressure: .critical).isEmpty)
    }

    func testBatteryBudgetCannotEvictRecentlyUsedTabs() {
        let tabs = (0..<8).map { tab(Double($0) / 10) }
        XCTAssertTrue(SleepPolicy.lean.onBattery().tabsToSleep(tabs, now: now).isEmpty)
    }
}

final class BatterySaverTests: XCTestCase {
    func testBatteryHalvesIdleTimesAndTrimsBudget() {
        let lean = SleepPolicy.lean.onBattery()
        XCTAssertEqual(lean.sleepAfter, SleepPolicy.lean.sleepAfter / 2)
        XCTAssertEqual(lean.hiddenSpaceSleepAfter, SleepPolicy.lean.hiddenSpaceSleepAfter / 2)
        XCTAssertEqual(lean.maxLiveTabs, 3)
        XCTAssertEqual(SleepPolicy.balanced.onBattery().maxLiveTabs, 6)
        XCTAssertEqual(SleepPolicy.never.onBattery(), .never)
    }
}
