import XCTest

final class SiteMatcherTests: XCTestCase {
    func testRegistrableDomain() {
        XCTAssertEqual(SiteMatcher.registrableDomain("accounts.google.com"), "google.com")
        XCTAssertEqual(SiteMatcher.registrableDomain("www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(SiteMatcher.registrableDomain("shop.example.com.au"), "example.com.au")
        XCTAssertEqual(SiteMatcher.registrableDomain("github.com"), "github.com")
        XCTAssertEqual(SiteMatcher.registrableDomain("192.168.1.20"), "192.168.1.20")
        XCTAssertEqual(SiteMatcher.registrableDomain("localhost"), "localhost")
        XCTAssertEqual(SiteMatcher.registrableDomain("a.b.example.io"), "example.io")
    }

    func testRank() {
        XCTAssertEqual(SiteMatcher.rank(savedHost: "github.com", pageHost: "GitHub.com"), 0)
        XCTAssertEqual(SiteMatcher.rank(savedHost: "accounts.example.com", pageHost: "www.example.com"), 1)
        XCTAssertNil(SiteMatcher.rank(savedHost: "example.com", pageHost: "example.org"))
        XCTAssertNil(SiteMatcher.rank(savedHost: "evil-example.com", pageHost: "example.com"))
        XCTAssertNil(SiteMatcher.rank(savedHost: "a.co.uk", pageHost: "b.co.uk"))
    }
}

final class PasswordCSVTests: XCTestCase {
    func testApplePasswordsExport() {
        let csv = """
        Title,URL,Username,Password,Notes,OTPAuth
        github.com (me),https://github.com/login,me@example.com,"pa,ss""word",,
        Example,https://www.example.com/,bob,secret,"multi
        line note",
        """
        let result = PasswordCSV.entries(from: csv)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.entries, [
            .init(host: "github.com", url: "https://github.com/login", username: "me@example.com", password: "pa,ss\"word"),
            .init(host: "www.example.com", url: "https://www.example.com/", username: "bob", password: "secret"),
        ])
    }

    func testChromeFirefoxAndBitwardenHeaders() {
        let chrome = "name,url,username,password,note\r\nsite,https://a.com,u,p,\r\n"
        XCTAssertEqual(PasswordCSV.entries(from: chrome).entries.map(\.host), ["a.com"])
        let firefox = "\u{FEFF}\"url\",\"username\",\"password\",\"httpRealm\"\n\"https://b.org\",\"v\",\"q\",\"\"\n"
        XCTAssertEqual(PasswordCSV.entries(from: firefox).entries.first?.username, "v")
        let bitwarden = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n"
            + ",,login,C,,,,\"https://c.net/a,https://d.net\",w,r,\n"
        XCTAssertEqual(PasswordCSV.entries(from: bitwarden).entries.first, .init(host: "c.net", url: "https://c.net/a", username: "w", password: "r"))
    }

    func testRowsWithoutSiteOrPasswordAreSkipped() {
        let csv = "url,username,password\n,u,p\nhttps://x.com,u,\nx.com,u,p\n"
        let result = PasswordCSV.entries(from: csv)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(result.entries.map(\.host), ["x.com"])
    }

    func testUnknownFormat() {
        XCTAssertTrue(PasswordCSV.entries(from: "a,b\n1,2\n").entries.isEmpty)
    }
}

/// Uses the real login keychain with a throwaway `.invalid` host, removed afterwards.
final class PasswordStoreTests: XCTestCase {
    let host = "feather-tests.invalid"

    override func tearDown() {
        for login in PasswordStore.shared.allLogins() where login.host == host { PasswordStore.shared.delete(login) }
    }

    func testKeychainRoundTrip() {
        let store = PasswordStore.shared
        XCTAssertTrue(store.save(host: host, username: "tester", password: "first-Secret1"))
        XCTAssertTrue(store.save(host: host, username: "tester", password: "second-Secret2"))  // updates, no duplicate
        let logins = store.allLogins().filter { $0.host == host }
        XCTAssertEqual(logins.map(\.username), ["tester"])
        XCTAssertEqual(logins.first.flatMap(store.password(for:)), "second-Secret2")
        XCTAssertEqual(store.logins(forHost: "login." + host).map(\.username), ["tester"])
        XCTAssertTrue(store.logins(forHost: "other-tests.invalid").isEmpty)
        logins.forEach(store.delete)
        XCTAssertTrue(store.allLogins().filter { $0.host == host }.isEmpty)
    }
}

final class StrongPasswordTests: XCTestCase {
    func testShapeAndVariety() {
        let samples = (0..<200).map { _ in StrongPassword.generate() }
        for password in samples {
            let groups = password.split(separator: "-")
            XCTAssertEqual(groups.count, 3)
            XCTAssertTrue(groups.allSatisfy { $0.count == 6 })
            XCTAssertTrue(password.contains(where: \.isUppercase))
            XCTAssertTrue(password.contains(where: \.isNumber))
        }
        XCTAssertEqual(Set(samples).count, samples.count)
    }
}

final class ArchivePolicyTests: XCTestCase {
    func testArchivesOnlyIdleUnpinnedBackgroundTabs() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-13 * 3600)
        let idle = ArchivePolicy.Facts(id: UUID(), lastActive: old)
        let fresh = ArchivePolicy.Facts(id: UUID(), lastActive: now.addingTimeInterval(-3600))
        let pinned = ArchivePolicy.Facts(id: UUID(), lastActive: old, isPinned: true)
        let visible = ArchivePolicy.Facts(id: UUID(), lastActive: old, isVisible: true)
        let audio = ArchivePolicy.Facts(id: UUID(), lastActive: old, isPlayingAudio: true)
        let typing = ArchivePolicy.Facts(id: UUID(), lastActive: old, hasUnsavedInput: true)
        let result = ArchivePolicy.tabsToArchive([idle, fresh, pinned, visible, audio, typing], now: now, after: 12 * 3600)
        XCTAssertEqual(result, [idle.id])
        XCTAssertTrue(ArchivePolicy.tabsToArchive([idle], now: now, after: .infinity).isEmpty)
    }
}

final class AutocompleteTests: XCTestCase {
    let candidates = [
        Autocomplete.Candidate(host: "www.youtube.com", score: 40),
        Autocomplete.Candidate(host: "youtu.be", score: 3),
        Autocomplete.Candidate(host: "yourbank.com", score: 40),
        Autocomplete.Candidate(host: "github.com", score: 10),
    ]

    func testCompletesBestHostIgnoringWWW() {
        XCTAssertEqual(Autocomplete.completion(for: "you", candidates: candidates), "youtube.com")  // tie → shorter host
        XCTAssertEqual(Autocomplete.completion(for: "your", candidates: candidates), "yourbank.com")
        XCTAssertEqual(Autocomplete.completion(for: "youtu.", candidates: candidates), "youtu.be")
        XCTAssertEqual(Autocomplete.completion(for: "GIT", candidates: candidates), "github.com")
    }

    func testNoCompletionForSearchesPathsOrExactHosts() {
        XCTAssertNil(Autocomplete.completion(for: "git hub", candidates: candidates))
        XCTAssertNil(Autocomplete.completion(for: "github.com/", candidates: candidates))
        XCTAssertNil(Autocomplete.completion(for: "github.com", candidates: candidates))
        XCTAssertNil(Autocomplete.completion(for: "", candidates: candidates))
    }
}

final class ConsentRulesTests: XCTestCase {
    // Shaped like autoconsent's compact-rules.json: rule [3] is a URL pattern, [4] the run context.
    let json = Data("""
        {"v": 1, "s": ["generic-a", "generic-b", "frame-c", "site-d"],
         "r": [[1, "generic", 2, "", 0], [1, "frame", 2, "", 1], [1, "example", 2, "^https?://(www\\\\.)?example\\\\.com/", 22]],
         "index": {"genericRuleRange": [0, 1], "frameRuleRange": [1, 2], "specificRuleRange": [2, 3],
                   "genericStringEnd": 2, "frameStringEnd": 3}}
        """.utf8)

    func testMainFrameGetsGenericRulesAndMatchingSiteRules() throws {
        let rules = try ConsentRules(json: json)
        let plain = rules.bundle(for: "https://other.org/", mainFrame: true)
        XCTAssertEqual((plain["r"] as? [[Any]])?.compactMap { $0[1] as? String }, ["generic"])
        XCTAssertEqual((plain["s"] as? [String])?.count, 2)
        let site = rules.bundle(for: "https://www.example.com/news", mainFrame: true)
        XCTAssertEqual((site["r"] as? [[Any]])?.compactMap { $0[1] as? String }, ["generic", "example"])
        XCTAssertEqual((site["s"] as? [String])?.count, 4)
    }

    func testFramesGetOnlyFrameRules() throws {
        let rules = try ConsentRules(json: json)
        let frame = rules.bundle(for: "https://www.example.com/", mainFrame: false)
        XCTAssertEqual((frame["r"] as? [[Any]])?.compactMap { $0[1] as? String }, ["frame"])
    }

    func testBundledRulesParse() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Feather/Resources/Consent/compact-rules.json")
        let rules = try ConsentRules(json: Data(contentsOf: url))
        let bundle = rules.bundle(for: "https://www.theguardian.com/", mainFrame: true)
        XCTAssertGreaterThan((bundle["r"] as? [Any])?.count ?? 0, 100)
    }
}

final class LinkCleanerTests: XCTestCase {
    func clean(_ text: String) -> String { LinkCleaner.clean(URL(string: text)!).absoluteString }

    func testRemovesTrackingKeepsMeaning() {
        XCTAssertEqual(clean("https://example.com/a?id=7&utm_source=x&utm_medium=y&fbclid=abc#top"), "https://example.com/a?id=7#top")
        XCTAssertEqual(clean("https://shop.example.com/?gclid=1&q=shoes"), "https://shop.example.com/?q=shoes")
        XCTAssertEqual(clean("https://example.com/?utm_campaign=z"), "https://example.com/")
    }

    func testSiteSpecificParameters() {
        XCTAssertEqual(clean("https://youtu.be/dQw4w9WgXcQ?si=Ab12&t=42"), "https://youtu.be/dQw4w9WgXcQ?t=42")
        XCTAssertEqual(clean("https://www.youtube.com/watch?v=abc&pp=ygU&t=10s"), "https://www.youtube.com/watch?v=abc&t=10s")
        XCTAssertEqual(clean("https://x.com/user/status/1?s=20&t=xyz"), "https://x.com/user/status/1")
        XCTAssertEqual(clean("https://www.amazon.co.uk/dp/B0?pd_rd_w=1&pf_rd_p=2&ref_=x&tag=creator-21"),
                       "https://www.amazon.co.uk/dp/B0?tag=creator-21")
        // `t` and `s` only mean tracking on X/Twitter.
        XCTAssertEqual(clean("https://example.com/?s=search&t=5"), "https://example.com/?s=search&t=5")
    }

    func testLeavesOtherURLsAlone() {
        XCTAssertEqual(clean("https://example.com/path"), "https://example.com/path")
        XCTAssertEqual(clean("about:blank"), "about:blank")
    }
}
