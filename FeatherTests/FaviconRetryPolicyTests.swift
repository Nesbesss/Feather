import XCTest

final class FaviconRetryPolicyTests: XCTestCase {
    func testFailedHostIsDeferredAndOtherHostsRemainAvailable() {
        var policy = FaviconRetryPolicy()
        policy.failed("missing.example", now: 100)

        XCTAssertFalse(policy.shouldAttempt("missing.example", now: 100))
        XCTAssertFalse(policy.shouldAttempt("missing.example", now: 159.999))
        XCTAssertTrue(policy.shouldAttempt("working.example", now: 110))
        XCTAssertTrue(policy.shouldAttempt("missing.example", now: 160))
    }

    func testRepeatedFailureStartsANewCooldownAndSuccessClearsIt() {
        var policy = FaviconRetryPolicy()
        policy.failed("site.example", now: 100)
        XCTAssertTrue(policy.shouldAttempt("site.example", now: 160))
        policy.failed("site.example", now: 165)
        XCTAssertFalse(policy.shouldAttempt("site.example", now: 224))

        policy.succeeded("site.example")
        XCTAssertTrue(policy.shouldAttempt("site.example", now: 224))
    }

    func testCapacityEvictsEarliestRetryWithoutBlockingUnseenHosts() {
        var policy = FaviconRetryPolicy(capacity: 2)
        policy.failed("first.example", now: 100)
        policy.failed("second.example", now: 101)
        policy.failed("third.example", now: 102)

        XCTAssertTrue(policy.shouldAttempt("first.example", now: 103))
        XCTAssertFalse(policy.shouldAttempt("second.example", now: 103))
        XCTAssertFalse(policy.shouldAttempt("third.example", now: 103))
        XCTAssertTrue(policy.shouldAttempt("unseen.example", now: 103))
    }

    func testExpiredFailuresDoNotEvictAnActiveFailure() {
        var policy = FaviconRetryPolicy(capacity: 2)
        policy.failed("active.example", now: 100)
        policy.failed("expired.example", now: 90)
        policy.failed("new.example", now: 151)

        XCTAssertFalse(policy.shouldAttempt("active.example", now: 151))
        XCTAssertTrue(policy.shouldAttempt("expired.example", now: 151))
        XCTAssertFalse(policy.shouldAttempt("new.example", now: 151))
    }
}
