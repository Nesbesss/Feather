import XCTest
import CoreGraphics

final class LaunchSplashMotionTests: XCTestCase {
    func testFlightArrivesAtTheCenteredReducedMotionStill() {
        for size in [CGSize(width: 640, height: 420), CGSize(width: 1280, height: 820), CGSize(width: 2560, height: 1440)] {
            let final = LaunchSplashMotion.pose(at: LaunchSplashMotion.duration, in: size)
            let reduced = LaunchSplashMotion.pose(at: 0, in: size, reduceMotion: true)
            XCTAssertEqual(final.point, reduced.point)
            XCTAssertEqual(final.angle, reduced.angle, accuracy: 0.00001)
            XCTAssertEqual(final.scale, reduced.scale, accuracy: 0.00001)
            XCTAssertEqual(final.featherOpacity, 1)
            XCTAssertEqual(final.wordmarkOpacity, 1)
            XCTAssertEqual(final.trailOpacity, 0)
            XCTAssertEqual(final.point.x, size.width * 0.5, accuracy: 0.00001)
            XCTAssertEqual(final.point.y, size.height * 0.43, accuracy: 0.00001)
        }
    }

    func testReducedMotionHasNoFlightOrTrailAtAnyTime() {
        let size = CGSize(width: 640, height: 420)
        let still = LaunchSplashMotion.pose(at: 0, in: size, reduceMotion: true)
        for frame in 0...180 {
            let pose = LaunchSplashMotion.pose(at: Double(frame) / 60, in: size, reduceMotion: true)
            XCTAssertEqual(pose, still)
            XCTAssertTrue(pose.trail.isEmpty)
        }
    }

    func testFlightIsDeterministicFiniteAndStaysWithinItsEntryAndViewportEnvelope() {
        for size in [CGSize(width: 640, height: 420), CGSize(width: 1280, height: 820), CGSize(width: 2560, height: 1440)] {
            for frame in 0...180 {
                let elapsed = Double(frame) / 60
                let pose = LaunchSplashMotion.pose(at: elapsed, in: size)
                XCTAssertEqual(pose, LaunchSplashMotion.pose(at: elapsed, in: size))
                XCTAssertTrue([pose.point.x, pose.point.y, pose.angle, pose.scale, pose.featherOpacity, pose.wordmarkOpacity, pose.trailOpacity].allSatisfy(\.isFinite))
                XCTAssertGreaterThanOrEqual(pose.point.x, -size.width * 0.121)
                XCTAssertLessThanOrEqual(pose.point.x, size.width)
                XCTAssertGreaterThanOrEqual(pose.point.y, 0)
                XCTAssertLessThanOrEqual(pose.point.y, size.height)
                XCTAssertTrue((0...1).contains(pose.featherOpacity))
                XCTAssertTrue((0...1).contains(pose.wordmarkOpacity))
                XCTAssertTrue((0.8...1.01).contains(pose.scale))
            }
        }
    }

    func testCubicJoinsHaveContinuousVelocityWithoutAStopOrTeleport() {
        let size = CGSize(width: 1280, height: 820)
        let epsilon = 0.00001
        for target in [1.0 / 3, 2.0 / 3] {
            // Invert the global quintic progress numerically to sample each join.
            var low = 0.0, high = 1.0
            for _ in 0..<60 {
                let p = (low + high) * 0.5
                let eased = p * p * p * (p * (p * 6 - 15) + 10)
                if eased < target { low = p } else { high = p }
            }
            let time = ((low + high) * 0.5) * LaunchSplashMotion.flightDuration
            let previous = LaunchSplashMotion.pose(at: time - epsilon, in: size).point
            let join = LaunchSplashMotion.pose(at: time, in: size).point
            let next = LaunchSplashMotion.pose(at: time + epsilon, in: size).point
            let left = CGPoint(x: (join.x - previous.x) / epsilon, y: (join.y - previous.y) / epsilon)
            let right = CGPoint(x: (next.x - join.x) / epsilon, y: (next.y - join.y) / epsilon)
            XCTAssertEqual(left.x, right.x, accuracy: 0.4)
            XCTAssertEqual(left.y, right.y, accuracy: 0.4)
            XCTAssertGreaterThan(hypot(left.x, left.y), 10)
        }
    }

    func testMotionClampsBeforeAndAfterItsPerformanceAndHandlesInvalidInputs() {
        let size = CGSize(width: 640, height: 420)
        XCTAssertEqual(LaunchSplashMotion.pose(at: -10, in: size), LaunchSplashMotion.pose(at: 0, in: size))
        XCTAssertEqual(LaunchSplashMotion.pose(at: 99, in: size), LaunchSplashMotion.pose(at: LaunchSplashMotion.duration, in: size))
        for time in [Double.nan, Double.infinity, -Double.infinity] {
            let pose = LaunchSplashMotion.pose(at: time, in: CGSize(width: .nan, height: -.infinity))
            XCTAssertTrue(pose.point.x.isFinite && pose.point.y.isFinite && pose.scale.isFinite)
        }
    }
}
