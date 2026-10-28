import AppKit
import Observation
import SwiftUI

/// AppKit owns the mask so the highlighted *real* control keeps receiving
/// mouse events. SwiftUI is only used for the small guide card, never the page.
@MainActor
final class TourOverlayView: NSView {
    var onBegin: (() -> Void)?
    var onSkip: (() -> Void)?
    var onNext: (() -> Void)?
    var onBack: (() -> Void)?

    private let coach = TourCoachModel()
    private var introHost: NSHostingView<TourIntroCard>?
    private var coachHost: NSHostingView<TourCoachCard>?
    private var playback: WelcomePlaybackState?
    private var target: NSRect?
    private var mode: Mode = .hidden
    private enum Mode { case hidden, intro, coach }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        setAccessibilityIdentifier("feather.tour.overlay")
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }

    func showIntro(playback: WelcomePlaybackState) {
        self.playback = playback
        if mode != .intro || introHost == nil {
            coachHost?.removeFromSuperview()
            coachHost = nil
            let host = NSHostingView(rootView: TourIntroCard(
                playback: playback,
                onBegin: { [weak self] in self?.begin() },
                onSkip: { [weak self] in self?.skip() }))
            introHost = host
            addSubview(host)
        }
        target = nil
        mode = .intro
        reveal()
    }

    func showCoach(title: String, message: String, step: Int, total: Int,
                   target: NSRect?, nextTitle: String?, allowsNext: Bool) {
        introHost?.removeFromSuperview()
        introHost = nil
        let changedStep = coach.step != step || mode != .coach
        if changedStep { clearSpaceCreator() }
        coach.title = title
        coach.message = message
        coach.step = step
        coach.total = max(1, total)
        coach.nextTitle = nextTitle
        coach.allowsNext = allowsNext
        coach.playback = playback
        self.target = target
        if coachHost == nil {
            let host = NSHostingView(rootView: TourCoachCard(model: coach,
                onSkip: { [weak self] in self?.skip() },
                onNext: { [weak self] in self?.onNext?() },
                onBack: { [weak self] in self?.onBack?() }))
            coachHost = host
            addSubview(host)
        }
        mode = .coach
        reveal(animate: changedStep)
    }

    func showSpaceCreator(defaultName: String, onCreate: @escaping (String) -> Void) {
        if !coach.creatingSpace { coach.spaceName = defaultName }
        coach.creatingSpace = true
        coach.onCreateSpace = onCreate
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func clearSpaceCreator() {
        coach.creatingSpace = false
        coach.spaceName = ""
        coach.onCreateSpace = nil
        needsLayout = true
    }

    func hide() {
        playback = nil
        coach.playback = nil
        introHost?.removeFromSuperview()
        introHost = nil
        coachHost?.removeFromSuperview()
        coachHost = nil
        target = nil
        clearSpaceCreator()
        mode = .hidden
        isHidden = true
        alphaValue = 1
    }

    override func layout() {
        super.layout()
        if let host = introHost {
            let width = max(280, min(560, bounds.width - 40))
            if host.rootView.availableWidth != width { host.rootView.availableWidth = width }
            let compact = bounds.height < 540
            if host.rootView.compact != compact { host.rootView.compact = compact }
            host.frame.size.width = width
            let height = host.fittingSize.height
            host.frame = NSRect(x: bounds.midX - width / 2,
                                y: max(16, bounds.midY - height / 2),
                                width: width, height: height)
        }
        if let host = coachHost {
            let width = max(260, min(344, bounds.width - 40))
            coach.width = width
            host.frame.size.width = width
            let height = host.fittingSize.height
            host.frame = coachFrame(width: width, height: height)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard mode != .hidden else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let mask = NSBezierPath(rect: bounds)
        if let spotlight {
            mask.appendRoundedRect(spotlight, xRadius: 10, yRadius: 10)
            mask.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(mode == .intro ? 0.24 : dark ? 0.34 : 0.2).setFill()
        mask.fill()
        if let spotlight {
            let ring = NSBezierPath(roundedRect: spotlight, xRadius: 10, yRadius: 10)
            ring.lineWidth = 2
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            ring.stroke()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, mode != .hidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let host = introHost, host.frame.contains(local) { return host.hitTest(local) }
        if let host = coachHost, host.frame.contains(local) { return host.hitTest(local) }
        if let spotlight, spotlight.contains(local) { return nil }
        return self
    }

    // The backdrop absorbs stray clicks but never changes or advances a step.
    override func mouseDown(with event: NSEvent) { }

    private var spotlight: NSRect? {
        guard mode == .coach, let target, !target.isEmpty else { return nil }
        let clipped = target.insetBy(dx: -6, dy: -6)
            .intersection(bounds.insetBy(dx: 3, dy: 3))
        return clipped.isEmpty ? nil : clipped
    }

    private func coachFrame(width: CGFloat, height: CGFloat) -> NSRect {
        let margin: CGFloat = 24
        let safe = bounds.insetBy(dx: margin, dy: margin)
        func positioned(x: CGFloat, y: CGFloat) -> NSRect {
            NSRect(x: min(max(safe.minX, x), max(safe.minX, safe.maxX - width)),
                   y: min(max(safe.minY, y), max(safe.minY, safe.maxY - height)),
                   width: width, height: height)
        }
        let right = positioned(x: safe.maxX - width, y: bounds.midY - height / 2)
        guard let spotlight else { return right }
        let padded = spotlight.insetBy(dx: -12, dy: -12)
        let candidates = [
            right,
            positioned(x: safe.minX, y: bounds.midY - height / 2),
            positioned(x: safe.maxX - width, y: spotlight.minY - height - 20),
            positioned(x: safe.maxX - width, y: spotlight.maxY + 20)
        ]
        return candidates.first(where: { !$0.intersects(padded) }) ?? right
    }

    private func reveal(animate: Bool = true) {
        let appearing = isHidden
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard animate, appearing, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            self.animator().alphaValue = 1
        }
    }

    private func begin() { onBegin?() }
    private func skip() { onSkip?() }
}

@Observable @MainActor
private final class TourCoachModel {
    var title = ""
    var message = ""
    var step = 0
    var total = 1
    var nextTitle: String?
    var allowsNext = false
    var width: CGFloat = 344
    var creatingSpace = false
    var spaceName = ""
    var onCreateSpace: ((String) -> Void)?
    var playback: WelcomePlaybackState?
}

private enum TourCardStyle {
    static let radius: CGFloat = 18
    static let border = Color.primary.opacity(0.12)
    static let accent = Color.accentColor
}

private struct TourIntroCard: View {
    let playback: WelcomePlaybackState
    let onBegin: () -> Void
    let onSkip: () -> Void
    var availableWidth: CGFloat = 560
    var compact = false
    @State private var elapsed = 0.0

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("FEATHER", systemImage: "sparkle")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                TourMusicToggle(playback: playback)
            }

            VStack(spacing: 8) {
                WelcomeOneShotClock(duration: WelcomeMotion.featherDuration,
                                    live: playback.live, elapsed: $elapsed) { time in
                    let pose = WelcomeMotion.featherPose(at: time)
                    Image("FeatherMark").resizable().scaledToFit()
                        .frame(width: compact ? 72 : 112, height: compact ? 72 : 112)
                        .rotationEffect(.degrees(pose.angle), anchor: .bottomLeading)
                        .offset(x: pose.x, y: pose.y * 0.65)
                }
                .frame(height: compact ? 72 : 112)
                .accessibilityHidden(true)

                Text("Make yourself at home.")
                    .font(.system(size: compact ? 25 : 29, weight: .medium, design: .rounded))
                    .tracking(-0.7).accessibilityAddTraits(.isHeader)
                Text("Let’s try the real controls together.\nA quick tour, right here in your browser.")
                    .font(.system(size: 13)).lineSpacing(3)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button {
                    playback.isMuted = false
                    playback.sound.play()
                } label: {
                    Label("Play music", systemImage: "play.fill")
                        .font(.system(size: 11)).frame(minHeight: 24)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("feather.tour.play-sound")
                Text(soundMessage)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: 230, alignment: .leading)
                    .accessibilityIdentifier("feather.tour.sound-status")
                Image(systemName: "speaker.wave.1")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { Double(playback.sound.musicVolume) },
                    set: { playback.sound.setVolume(Float($0)) }
                ), in: 0...1)
                .frame(width: 80)
                .accessibilityLabel("Tour music volume")
                .accessibilityIdentifier("feather.tour.music-volume")
            }

            HStack {
                Button("Skip tour", action: onSkip)
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("feather.tour.skip")
                Spacer()
                Button("Show me around", action: onBegin)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("feather.tour.begin")
            }
        }
        .padding(compact ? 20 : 24)
        .frame(width: availableWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: TourCardStyle.radius))
        .overlay(RoundedRectangle(cornerRadius: TourCardStyle.radius)
            .strokeBorder(TourCardStyle.border, lineWidth: 0.75))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 10)
    }

    private var soundMessage: String {
        if playback.sound.status == .failed {
            return "Music couldn’t play. You can still take the tour."
        }
        if playback.isMuted { return "Music paused" }
        switch playback.sound.status {
        case .playing: return "Music playing…"
        case .paused: return "Music paused"
        case .idle, .finished, .stopped, .failed: return "Peaceful music for your tour."
        }
    }
}

private struct TourCoachCard: View {
    @Bindable var model: TourCoachModel
    let onSkip: () -> Void
    let onNext: () -> Void
    let onBack: () -> Void
    @FocusState private var namingSpace: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("TRY IT · \(max(1, model.step)) OF \(model.total)")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.1)
                    .foregroundStyle(.secondary)
                Spacer()
                if let playback = model.playback {
                    TourMusicToggle(playback: playback, compact: true)
                }
                Button("Skip tour", action: onSkip)
                    .font(.system(size: 10)).buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("feather.tour.skip")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.title)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .tracking(-0.35).accessibilityAddTraits(.isHeader)
                Text(model.message)
                    .font(.system(size: 12)).lineSpacing(4)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.creatingSpace {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Space name", text: $model.spaceName)
                        .textFieldStyle(.roundedBorder)
                        .focused($namingSpace)
                        .onSubmit(createSpace)
                        .accessibilityIdentifier("feather.tour.space-name")
                    Button("Create space", action: createSpace)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.spaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("feather.tour.create-space")
                }
            }
            HStack {
                if model.step > 1 {
                    Button("Back", action: onBack)
                        .font(.system(size: 11)).buttonStyle(.borderless)
                        .accessibilityIdentifier("feather.tour.back")
                }
                Spacer()
                if !model.creatingSpace {
                    Button(model.nextTitle ?? (model.allowsNext ? "Continue" : "Skip step"), action: onNext)
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("feather.tour.next")
                }
            }
        }
        .padding(22)
        .frame(width: model.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: TourCardStyle.radius))
        .overlay(RoundedRectangle(cornerRadius: TourCardStyle.radius)
            .strokeBorder(TourCardStyle.border, lineWidth: 0.75))
        .shadow(color: .black.opacity(0.13), radius: 22, y: 8)
        .onChange(of: model.creatingSpace) { _, creating in namingSpace = creating }
    }

    private func createSpace() {
        let name = model.spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.onCreateSpace?(name)
    }
}

/// The same shared mute state follows the user through every tour step.
private struct TourMusicToggle: View {
    let playback: WelcomePlaybackState
    var compact = false

    var body: some View {
        Button {
            playback.isMuted.toggle()
            playback.playClick()
        } label: {
            Group {
                if compact {
                    Image(systemName: playback.isMuted ? "speaker.slash" : "speaker.wave.2")
                        .frame(width: 24, height: 24)
                } else {
                    Label(playback.isMuted ? "Muted" : "Music on",
                          systemImage: playback.isMuted ? "speaker.slash" : "speaker.wave.2")
                        .frame(minHeight: 30)
                }
            }
            .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .help(playback.isMuted ? "Resume tour music" : "Mute tour music")
        .accessibilityLabel(playback.isMuted ? "Resume tour music" : "Mute tour music")
        .accessibilityIdentifier("feather.tour.sound-toggle")
    }
}
