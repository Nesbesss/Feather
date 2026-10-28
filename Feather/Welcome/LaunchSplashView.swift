import SwiftUI

/// The existing feather mark takes one curved flight, then rests above the name.
/// No independent animation clocks, repeated loops, sound, or layout movement.
struct LaunchSplashView: View {
    let elapsed: TimeInterval
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let pose = LaunchSplashMotion.pose(at: elapsed, in: size, reduceMotion: reduceMotion)
            let markSize = LaunchSplashMotion.markSize(in: size)
            ZStack {
                LinearGradient(colors: dark
                    ? [Color(red: 0.075, green: 0.125, blue: 0.15), Color(red: 0.045, green: 0.08, blue: 0.10)]
                    : [Color(red: 0.86, green: 0.93, blue: 0.94), Color(red: 0.72, green: 0.83, blue: 0.88)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(dark ? 0.045 : 0.25), .clear],
                               center: .init(x: 0.5, y: 0.43), startRadius: 0,
                               endRadius: min(size.width, size.height) * 0.62)
                if !pose.trail.isEmpty {
                    Canvas { context, _ in
                        for index in 1..<pose.trail.count {
                            var line = Path()
                            line.move(to: pose.trail[index - 1])
                            line.addLine(to: pose.trail[index])
                            let strength = Double(index) / Double(pose.trail.count - 1)
                            context.stroke(line, with: .color(.white.opacity(strength * 0.31 * pose.trailOpacity)),
                                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        }
                    }
                    .allowsHitTesting(false)
                }
                Image("FeatherMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: markSize, height: markSize)
                    .shadow(color: .black.opacity(dark ? 0.20 : 0.11), radius: 18, x: 0, y: 12)
                    .scaleEffect(pose.scale)
                    .rotationEffect(.degrees(pose.angle))
                    .position(pose.point)
                    .opacity(pose.featherOpacity)
                    .accessibilityHidden(true)
                Text("Feather")
                    .font(.system(size: size.height < 500 ? 27 : 31, weight: .medium, design: .rounded))
                    .tracking(0.3)
                    .foregroundStyle(dark ? Color.white.opacity(0.92) : Color(red: 0.16, green: 0.29, blue: 0.34))
                    .position(x: size.width * 0.5, y: size.height * 0.43 + markSize * 0.5 + 29)
                    .opacity(pose.wordmarkOpacity)
                    .accessibilityHidden(true)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Feather is opening")
        .accessibilityIdentifier("feather.launch-splash.artwork")
    }
}
