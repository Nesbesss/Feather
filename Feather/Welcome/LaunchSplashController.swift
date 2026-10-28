import AppKit
import Observation
import SwiftUI

@Observable @MainActor
private final class LaunchSplashPlayback {
    var elapsed: TimeInterval = 0
    var reduceMotion = false
}

/// A bounded introduction inside the existing browser window. Session restore
/// and page loading proceed underneath; completion only gates launch UI.
@MainActor
final class LaunchSplashController {
    private weak var window: NSWindow?
    private let playback = LaunchSplashPlayback()
    private var overlay: NSHostingView<LaunchSplashPresentation>!
    private let reducedOverride: Bool?
    private let activityOverride: (() -> Bool)?
    private var timer: Timer?
    private var lastUptime: TimeInterval?
    private var deadline: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var closeObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var onFinish: (() -> Void)?
    private var started = false
    private var ending = false

    var isShowing: Bool { overlay.superview != nil }
    var elapsed: TimeInterval { playback.elapsed }
    private var duration: TimeInterval {
        playback.reduceMotion ? LaunchSplashMotion.reducedDuration : LaunchSplashMotion.duration
    }

    init(in container: NSView, window: NSWindow, reduceMotion: Bool? = nil, activity: (() -> Bool)? = nil) {
        self.window = window
        reducedOverride = reduceMotion
        activityOverride = activity
        playback.reduceMotion = reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        overlay = NSHostingView(rootView: LaunchSplashPresentation(playback: playback, onSkip: {}))
        overlay.rootView = LaunchSplashPresentation(playback: playback, onSkip: { [weak self] in self?.dismiss() })
        overlay.sizingOptions = []
        overlay.wantsLayer = true
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.setAccessibilityIdentifier("feather.launch-splash")
        overlay.setAccessibilityLabel("Feather is opening")
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
    }

    func start(onFinish: @escaping () -> Void) {
        guard !started, !ending else { return }
        started = true
        self.onFinish = onFinish
        observeActivity()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, !self.ending else { return event }
            if event.modifierFlags.contains(.command) {
                let character = event.charactersIgnoringModifiers?.lowercased()
                if character == "q" { self.cancel() }
                else { self.dismiss(afterCurrentEvent: character == "w") }
                return event
            }
            if [UInt16(53), 36, 49].contains(event.keyCode) { self.dismiss() }
            // Do not type into a restored website behind the introduction.
            return nil
        }
        let deadline = DispatchWorkItem { [weak self] in self?.finish(animated: false) }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: deadline)
        updateActivity()
    }

    /// Click, Escape, Return, Space, or a browser command reveals the page at once.
    func dismiss(afterCurrentEvent: Bool = false) { finish(animated: false, afterCurrentEvent: afterCurrentEvent) }

    /// Closing a window must not start its first-run guide or authorization UI.
    func cancel() {
        onFinish = nil
        ending = true
        cleanUp()
        removeCloseObserver()
        overlay.removeFromSuperview()
    }

    func updateActivity() {
        guard started, !ending else { return }
        playback.reduceMotion = reducedOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if playback.elapsed >= duration { finish(animated: !playback.reduceMotion); return }
        let live = activityOverride?() ?? (NSApp.isActive && window?.isVisible == true
            && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true)
        guard live else {
            timer?.invalidate()
            timer = nil
            lastUptime = nil
            return
        }
        guard timer == nil else { return }
        lastUptime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.003
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard !ending else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let previous = lastUptime else { lastUptime = now; return }
        lastUptime = now
        playback.elapsed = min(duration, playback.elapsed + min(0.1, max(0, now - previous)))
        if playback.elapsed >= duration { finish(animated: !playback.reduceMotion) }
    }

    private func finish(animated: Bool, afterCurrentEvent: Bool = false) {
        guard !ending else { return }
        ending = true
        cleanUp()
        let live = NSApp.isActive && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        if animated && live {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = LaunchSplashMotion.fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                overlay.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.complete() }
            }
        } else if afterCurrentEvent {
            // Cmd+W can close a tab while leaving the window alive. Let its
            // normal action run first; an actual window close cancels this
            // completion through windowWillClose instead of starting a guide.
            overlay.removeFromSuperview()
            DispatchQueue.main.async { [weak self] in self?.complete() }
        } else { complete() }
    }

    private func complete() {
        removeCloseObserver()
        overlay.removeFromSuperview()
        let completion = onFinish
        onFinish = nil
        completion?()
    }

    private func observeActivity() {
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActivity() }
            }
            observers.append((.default, token))
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        let terminated = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        observers.append((.default, terminated))
        for center in [NotificationCenter.default, NSWorkspace.shared.notificationCenter] {
            let token = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActivity() }
            }
            observers.append((center, token))
        }
    }

    private func cleanUp() {
        timer?.invalidate()
        timer = nil
        lastUptime = nil
        deadline?.cancel()
        deadline = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
    }

    private func removeCloseObserver() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }
}

private struct LaunchSplashPresentation: View {
    let playback: LaunchSplashPlayback
    let onSkip: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LaunchSplashView(elapsed: playback.elapsed, reduceMotion: playback.reduceMotion)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSkip)
            Button(action: onSkip) {
                HStack(spacing: 6) {
                    Text("Skip")
                    Text("esc").font(.system(size: 10, design: .monospaced)).opacity(0.7)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip opening animation")
            .accessibilityIdentifier("feather.launch-splash.skip")
            .padding(24)
        }
        .accessibilityElement(children: .contain)
    }
}
