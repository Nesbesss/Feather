import SwiftUI

/// The welcome illustration gets one short performance, then its clock stops.
/// Adapted from rossark-motion-skill's one-shot engine; uptime keeps wall-clock
/// changes from affecting the feather and a cancelled task preserves its pose.
struct WelcomeOneShotClock<Content: View>: View {
    let duration: Double
    let live: Bool
    @ViewBuilder let content: (Double) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var elapsed: Double

    init(duration: Double, live: Bool, elapsed: Binding<Double>,
         @ViewBuilder content: @escaping (Double) -> Content) {
        self.duration = duration
        self.live = live
        self._elapsed = elapsed
        self.content = content
    }

    var body: some View {
        content(reduceMotion ? duration : elapsed)
            .task(id: live && !reduceMotion) {
                guard live, !reduceMotion, elapsed < duration else { return }
                let start = ProcessInfo.processInfo.systemUptime
                let carried = elapsed
                while !Task.isCancelled, elapsed < duration {
                    elapsed = min(duration, carried + ProcessInfo.processInfo.systemUptime - start)
                    do { try await Task.sleep(for: .milliseconds(16)) }
                    catch { return }
                }
            }
            .onChange(of: reduceMotion, initial: true) { _, reduced in
                if reduced { elapsed = duration }
            }
    }
}

enum WelcomeMotion {
    static let featherDuration = 2.15
    static let pageDuration = 0.2
    static let soundDelay = 0.7
    static let arrival = UnitCurve.bezier(startControlPoint: .init(x: 0.23, y: 1),
                                         endControlPoint: .init(x: 0.32, y: 1))

    /// Continuous, gently decaying drift around a downward arc. The final pose
    /// is identical to the reduced-motion still, with no idle loop afterward.
    static func featherPose(at elapsed: Double) -> (x: Double, y: Double, angle: Double) {
        let p = min(1, max(0, elapsed / featherDuration))
        let landing = arrival.value(at: p)
        let drift = sin(p * .pi * 2) * (1 - p)
        return (22 * drift, -124 * (1 - landing), -17 * (1 - landing) + 10 * drift)
    }
}
