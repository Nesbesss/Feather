import XCTest

final class SessionCodecTests: XCTestCase {
    func testRoundTripKeepsInteractionState() throws {
        let tab = TabRecord(id: UUID(), url: "https://example.com", title: "Example",
                            lastActive: Date(timeIntervalSince1970: 1_700_000_000), interactionState: Data([1, 2, 3, 255]))
        let space = SpaceRecord(id: UUID(), name: "Home", hue: 0.6, dataStoreID: UUID(),
                                pinned: [tab], tabs: [], lastSelectedTabID: tab.id)
        let session = SessionRecord(spaces: [space],
                                    windows: [WindowRecord(spaceID: space.id, primaryTabID: tab.id, frame: "{{0, 0}, {800, 600}}")],
                                    recentlyClosed: [ClosedTabRecord(tab: tab, spaceID: space.id, index: 0)])
        XCTAssertEqual(try SessionCodec.decode(SessionCodec.encode(session)), session)
    }
}

final class BlocklistConverterTests: XCTestCase {
    func testParsesHostsAndDropsCoveredSubdomains() {
        let hosts = """
        # comment
        127.0.0.1 localhost
        0.0.0.0 0.0.0.0
        0.0.0.0 ads.example.com
        0.0.0.0 example.com   # trailing comment
        0.0.0.0 tracker.net cdn.tracker.net
        ::1 ip6-localhost
        0.0.0.0 bad_char$.com
        """
        XCTAssertEqual(BlocklistConverter.domains(fromHosts: hosts), ["example.com", "tracker.net"])
    }

    func testRuleShape() throws {
        let data = try BlocklistConverter.networkRules(for: ["ads.example.com"])
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: [String: Any]]])
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0]["trigger"]?["url-filter"] as? String, "^[^:]+://+([^:/]+\\.)?ads\\.example\\.com[:/]")
        XCTAssertEqual(rules[0]["trigger"]?["load-type"] as? [String], ["third-party"])
        XCTAssertEqual(rules[0]["action"]?["type"] as? String, "block")
    }

    func testURLFilterMatchesDomainAndSubdomainsOnly() throws {
        let regex = try NSRegularExpression(pattern: BlocklistConverter.urlFilter(for: "ads.com"))
        func matches(_ s: String) -> Bool { regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        XCTAssertTrue(matches("https://ads.com/x.js"))
        XCTAssertTrue(matches("https://cdn.ads.com:443/x.js"))
        XCTAssertFalse(matches("https://notads.com/x.js"))
        XCTAssertFalse(matches("https://example.com/ads.com/x.js"))
    }
}
