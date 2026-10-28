import XCTest

final class SidebarPolicyTests: XCTestCase {
    private func hides(_ mode: SidebarMode = .smart, collapsed: Bool = false, width: Double = 1400, override: Bool? = nil,
                       advice: Bool? = nil, layout: Bool? = nil) -> Bool {
        SidebarPolicy.hides(mode: mode, manuallyCollapsed: collapsed, windowWidth: width, override: override,
                            advice: advice, layoutSuggestsHiding: layout)
    }

    func testShowAndAutoHideIgnoreTheSite() {
        XCTAssertFalse(hides(.show, layout: true))
        XCTAssertTrue(hides(.show, collapsed: true))
        XCTAssertTrue(hides(.autoHide, layout: false))
    }

    func testSmartHidesForOwnSidebarUnlessAppleIntelligenceSaysNo() {
        XCTAssertFalse(hides(layout: nil))
        XCTAssertFalse(hides(advice: true, layout: false))  // the model is only consulted when the layout suggests it
        XCTAssertTrue(hides(layout: true))
        XCTAssertFalse(hides(advice: false, layout: true))
        XCTAssertTrue(hides(advice: true, layout: true))
    }

    func testNarrowWindowsAndYourChoice() {
        XCTAssertTrue(hides(width: 900, layout: false))
        XCTAssertFalse(hides(width: 900, override: false))
        XCTAssertTrue(hides(override: true, advice: false, layout: false))
    }

    func testLayoutMessageParsing() {
        let layout = PageLayout(message: ["sidebar": 256.0, "labels": ["Inbox", "Starred"], "app": true] as [String: Any])
        XCTAssertEqual(layout, PageLayout(ownSidebarWidth: 256, navLabels: ["Inbox", "Starred"], appLike: true))
        XCTAssertEqual(PageLayout(message: ["sidebar": NSNull(), "labels": [String](), "app": false] as [String: Any])?.suggestsHiding, false)
    }
}

final class TabClusteringTests: XCTestCase {
    /// Points on a line: two tight groups far apart, and one point on its own.
    private func lineDistances(_ positions: [Double]) -> [[Double]] {
        positions.map { a in positions.map { b in abs(a - b) } }
    }

    func testHDBSCANFindsDenseGroupsAndLeavesNoise() {
        let labels = HDBSCAN.labels(distances: lineDistances([0, 0.1, 0.2, 5, 5.1, 5.2, 12]), minimumClusterSize: 2, neighbors: 2)
        XCTAssertEqual(Set(labels[0...2]).count, 1)
        XCTAssertEqual(Set(labels[3...5]).count, 1)
        XCTAssertNotEqual(labels[0], labels[3])
        XCTAssertEqual(labels[6], -1)
        XCTAssertTrue(labels[0...5].allSatisfy { $0 >= 0 })
    }

    func testHDBSCANOneTightGroupNeedsAllowSingleCluster() {
        let distances = lineDistances([0, 0.1, 0.2])
        XCTAssertEqual(HDBSCAN.labels(distances: distances, minimumClusterSize: 2, neighbors: 2, allowSingleCluster: true), [0, 0, 0])
        XCTAssertEqual(HDBSCAN.labels(distances: [[0]], minimumClusterSize: 2, neighbors: 2), [-1])
    }

    func testGroupsDropMembersFarFromTheRest() {
        // 0–2 are close; 3 is close to nobody but would be pulled in as the group's nearest point.
        let d: [[Double]] = [
            [0, 0.1, 0.1, 0.95],
            [0.1, 0, 0.1, 0.95],
            [0.1, 0.1, 0, 0.95],
            [0.95, 0.95, 0.95, 0],
        ]
        XCTAssertEqual(TabClustering.groups(of: [0, 1, 2, 3], d), [[0, 1, 2]])
    }

    func testAttachJoinsOnlyCloseGroups() {
        let d: [[Double]] = [
            [0, 0.2, 0.9],   // tab 0: near group A (index 1), far from B (index 2)
            [0.2, 0, 0.9],
            [0.9, 0.9, 0],
        ]
        XCTAssertEqual(TabClustering.attach(0, to: [[1], [2]], d), 0)
        XCTAssertNil(TabClustering.attach(2, to: [[0, 1]], d))
    }

    func testCenteredDistances() {
        let d = TabClustering.distances([[1, 0, 1], [1, 0, 1], [1, 1, 0], [1, 1, 0]])
        XCTAssertEqual(d[0][1], 0, accuracy: 1e-9)
        XCTAssertGreaterThan(d[0][2], 1.5)  // after removing the shared direction they point apart
    }

    func testFallbackGroupsByTopicAndSiteNames() {
        XCTAssertEqual(TabClustering.groupsByTopic(["Travel: flights", "Swift: docs", "travel: hotels", nil, "Swift: repo"]),
                       [[0, 2], [1, 4]])
        XCTAssertEqual(TabClustering.siteName("www.booking.com"), "booking")
        XCTAssertEqual(TabClustering.siteName("developer.apple.com"), "developer")  // Safari's pattern drops every short label
    }

    func testNamesAreShortAndClean() {
        XCTAssertEqual(TabClustering.cleanName("  \"AI 🤖 Research\"  "), "AI Research")
        XCTAssertEqual(TabClustering.cleanName("Travel\nand more"), "Travel")
        XCTAssertEqual(TabClustering.cleanName(String(repeating: "a", count: 40)).count, TabClustering.maxNameLength)
        XCTAssertEqual(TabClustering.cleanName("Headphones comparing noise cancelling"), "Headphones comparing")
    }
}

final class TabGroupSessionTests: XCTestCase {
    func testGroupsRoundTrip() throws {
        let group = TabGroupRecord(id: UUID(), name: "Travel", collapsed: true, automatic: true)
        let tab = TabRecord(id: UUID(), url: "https://booking.com", title: "Hotels", lastActive: Date(timeIntervalSince1970: 1_700_000_000),
                            interactionState: nil, groupID: group.id, noAutoGroup: true)
        let space = SpaceRecord(id: UUID(), name: "Home", hue: 0.6, dataStoreID: nil, pinned: [], tabs: [tab],
                                lastSelectedTabID: nil, groups: [group])
        let session = SessionRecord(spaces: [space], windows: [])
        XCTAssertEqual(try SessionCodec.decode(SessionCodec.encode(session)), session)
    }
}
