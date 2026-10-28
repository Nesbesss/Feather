import Foundation
import CoreGraphics

/// One deterministic flight. The AppKit owner supplies a single monotonic clock;
/// no motion or timers remain once the splash leaves the browser window.
nonisolated enum LaunchSplashMotion {
    static let duration: TimeInterval = 2.2
    static let flightDuration: TimeInterval = 1.85
    static let reducedDuration: TimeInterval = 0.35
    static let fadeDuration: TimeInterval = 0.22

    struct Pose: Equatable, Sendable {
        let point: CGPoint
        let angle: Double
        let scale: Double
        let featherOpacity: Double
        let wordmarkOpacity: Double
        let trail: [CGPoint]
        let trailOpacity: Double
    }

    static func pose(at elapsed: TimeInterval, in size: CGSize, reduceMotion: Bool = false) -> Pose {
        let size = CGSize(width: max(0, size.width.isFinite ? size.width : 0),
                          height: max(0, size.height.isFinite ? size.height : 0))
        let time = elapsed.isFinite ? min(duration, max(0, elapsed)) : duration
        let final = CGPoint(x: size.width * 0.5, y: size.height * 0.43)
        guard !reduceMotion else {
            return Pose(point: final, angle: 0, scale: 1, featherOpacity: 1,
                        wordmarkOpacity: 1, trail: [], trailOpacity: 0)
        }
        let progress = min(1, time / flightDuration)
        let settle = smoothstep((progress - 0.64) / 0.36)
        let angle = (20 * sin(progress * .pi * 2 - 0.7)
                     + 5 * sin(progress * .pi * 5) * (1 - progress)) * (1 - settle)
        let scale = 0.82 + 0.18 * smoothstep(progress)
        let trailOpacity = smoothstep(time / 0.24) * (1 - smoothstep((time - 1.58) / 0.38))
        let trail: [CGPoint] = trailOpacity > 0 ? (0...24).map { index in
            flightPoint(at: max(0, time - 0.3 + Double(index) * 0.3 / 24), in: size)
        } : []
        return Pose(point: flightPoint(at: time, in: size), angle: angle, scale: scale,
                    featherOpacity: smoothstep(time / 0.16),
                    wordmarkOpacity: smoothstep((time - 1.4) / 0.4),
                    trail: trail, trailOpacity: trailOpacity)
    }

    static func markSize(in size: CGSize) -> CGFloat {
        min(148, max(96, min(size.width * 0.17, size.height * 0.28)))
    }

    /// Three cubic curves share their join tangents. A single quintic timing
    /// curve crosses both joins without stopping, then comes to rest at center.
    private static func flightPoint(at elapsed: TimeInterval, in size: CGSize) -> CGPoint {
        let progress = min(1, max(0, elapsed / flightDuration))
        let eased = progress * progress * progress * (progress * (progress * 6 - 15) + 10)
        let index = min(2, Int(eased * 3))
        let t = min(1, eased * 3 - Double(index))
        let inverse = 1 - t
        let points = curves[index]
        let weights = [inverse * inverse * inverse, 3 * inverse * inverse * t,
                       3 * inverse * t * t, t * t * t]
        let x = zip(points, weights).reduce(0.0) { $0 + Double($1.0.x) * $1.1 }
        let y = zip(points, weights).reduce(0.0) { $0 + Double($1.0.y) * $1.1 }
        return CGPoint(x: size.width * x, y: size.height * y)
    }

    private static let curves: [[CGPoint]] = [
        [.init(x: -0.12, y: 0.60), .init(x: 0.15, y: 0.19),
         .init(x: 0.39, y: 0.10), .init(x: 0.68, y: 0.22)],
        [.init(x: 0.68, y: 0.22), .init(x: 0.97, y: 0.34),
         .init(x: 0.91, y: 0.76), .init(x: 0.60, y: 0.70)],
        [.init(x: 0.60, y: 0.70), .init(x: 0.29, y: 0.64),
         .init(x: 0.24, y: 0.30), .init(x: 0.50, y: 0.43)]
    ]

    private static func smoothstep(_ value: Double) -> Double {
        let value = min(1, max(0, value))
        return value * value * (3 - 2 * value)
    }
}
