import XCTest

final class URLInputTests: XCTestCase {
    func url(_ text: String) -> (String, [String])? {
        guard case .url(let url, let fallbacks)? = URLInput.resolve(text) else { return nil }
        return (url.absoluteString, fallbacks.map(\.absoluteString))
    }

    func isSearch(_ text: String) -> Bool {
        if case .search? = URLInput.resolve(text) { return true }
        return false
    }

    func testBareDomainPrefersHTTPSWithHTTPFallback() {
        XCTAssertEqual(url("example.com")?.0, "https://example.com")
        XCTAssertEqual(url("example.com")?.1, ["http://example.com"])
        XCTAssertEqual(url("news.ycombinator.com/item?id=1")?.0, "https://news.ycombinator.com/item?id=1")
    }

    func testExplicitSchemesAreKept() {
        XCTAssertEqual(url("http://example.com")?.0, "http://example.com")
        XCTAssertEqual(url("https://a.b/c d")?.0, "https://a.b/c%20d")
        XCTAssertEqual(url("about:blank")?.0, "about:blank")
        XCTAssertEqual(url("mailto:me@example.com")?.0, "mailto:me@example.com")
    }

    func testLocalHostsUseHTTP() {
        XCTAssertEqual(url("localhost:3000")?.0, "http://localhost:3000")
        XCTAssertEqual(url("192.168.1.10/admin")?.0, "http://192.168.1.10/admin")
        XCTAssertEqual(url("app.localhost")?.0, "http://app.localhost")
    }

    func testHostWithPortIsNotAScheme() {
        XCTAssertEqual(url("example.com:8080/x")?.0, "https://example.com:8080/x")
    }

    func testSearches() {
        XCTAssertTrue(isSearch("swift observation framework"))
        XCTAssertTrue(isSearch("hello"))
        XCTAssertTrue(isSearch("1.5"))
        XCTAssertTrue(isSearch("javascript:alert(1)"))
        XCTAssertTrue(isSearch("define:browser"))
        XCTAssertNil(URLInput.resolve("   "))
    }

    func testSearchURLEncodesQuery() {
        let url = URLInput.searchURL(for: "a&b c?", template: "https://duckduckgo.com/?q=%s")
        XCTAssertEqual(url?.absoluteString, "https://duckduckgo.com/?q=a%26b%20c%3F")
    }
}
