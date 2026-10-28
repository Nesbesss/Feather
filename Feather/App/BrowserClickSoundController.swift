import AppKit

/// App-local interaction feedback. No global input monitor or page scripts;
/// event contents, typed text, URLs, and click locations are never recorded.
@MainActor
final class BrowserClickSoundController {
    static let shared = BrowserClickSoundController()

    private weak var settings: AppSettings?
    private let voice = WelcomeSound(resourceURL: nil)
    private var observation: ObservationLoop?
    private var monitor: Any?
    private var typingMonitor: Any?
    private var movementObservers: [NSObjectProtocol] = []
    private var gesture = ClickGesturePolicy()
    private weak var tourWindow: NSWindow?
    private var permitsTourClicks: (() -> Bool)?
    private var globalClicks = 0
    private var tourClicks = 0
    private var typingSounds = 0
    private var typingVariations = Set<Int>()
    private let reportURL: URL? = {
        guard ProcessInfo.processInfo.arguments.contains("-FeatherClickAudioReport"),
              let path = UserDefaults.standard.string(forKey: "FeatherClickAudioReport"),
              path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }()

    func start(settings: AppSettings) {
        stop()
        self.settings = settings
        observation = ObservationLoop { [weak self] in
            guard let self, let settings = self.settings else { return }
            self.apply(settings.clickSoundScope, typingScope: settings.typingSoundScope)
        }
    }

    func registerTour(in window: NSWindow, permitsClicks: @escaping () -> Bool) {
        tourWindow = window
        permitsTourClicks = permitsClicks
        updateTypingMonitor()
    }

    func unregisterTour(in window: NSWindow?) {
        guard window == nil || tourWindow === window else { return }
        tourWindow = nil
        permitsTourClicks = nil
        if settings?.clickSoundScope != .everywhere && settings?.typingSoundScope != .everywhere { voice.stop() }
        updateTypingMonitor()
        writeReport()
    }

    @discardableResult
    func playTourClick() -> Bool {
        guard settings?.clickSoundScope != nil, settings?.clickSoundScope != .off,
              permitsTourClicks?() == true else { return false }
        // A shortcut or Return can activate the same action as a mouse click.
        // Keep keyboard activation quiet as well as ordinary typing.
        if let type = NSApp.currentEvent?.type,
           type == .keyDown || type == .keyUp || type == .flagsChanged { return false }
        let accepted = voice.playClick()
        if accepted { tourClicks += 1 }
        writeReport()
        return accepted
    }

    private func apply(_ scope: ClickSoundScope, typingScope: ClickSoundScope) {
        if scope == .everywhere {
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                    self?.handle(event)
                    return event
                }
                for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                             NSApplication.didResignActiveNotification] {
                    movementObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.gesture.cancel() }
                    })
                }
            }
        } else {
            removeMonitor()
            if scope == .off && typingScope == .off { voice.stop() }
        }
        updateTypingMonitor()
        writeReport()
    }

    private func updateTypingMonitor() {
        let scope = settings?.typingSoundScope ?? .off
        let needed = scope == .everywhere || (scope == .tour && tourWindow != nil)
        if needed, typingMonitor == nil {
            voice.prepareTyping()
            typingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleTyping(event)
                return event
            }
        } else if !needed {
            if let typingMonitor { NSEvent.removeMonitor(typingMonitor) }
            self.typingMonitor = nil
            voice.stopTyping()
        }
    }

    private func handleTyping(_ event: NSEvent) {
        guard NSApp.isActive, let window = event.window,
              let scope = settings?.typingSoundScope, scope != .off else { return }
        if window === tourWindow {
            guard permitsTourClicks?() == true else { return }
        } else if scope != .everywhere { return }
        // AppKit field editors and WebKit expose an input context while
        // accepting text. This keeps page shortcuts and focused buttons quiet.
        guard let editor = window.firstResponder as? NSView, editor.inputContext != nil else { return }
        if let text = editor as? NSTextView, !text.isEditable { return }
        let flags = event.modifierFlags
        guard TypingGesturePolicy.shouldPlay(keyCode: event.keyCode, characters: event.characters,
            command: flags.contains(.command), control: flags.contains(.control),
            option: flags.contains(.option)) else { return }
        if voice.playTyping(keyCode: event.keyCode) {
            typingSounds += 1
            if reportURL != nil, let sample = voice.lastTypingSampleID { typingVariations.insert(sample) }
        }
        writeReport()
    }

    private func handle(_ event: NSEvent) {
        guard settings?.clickSoundScope == .everywhere, NSApp.isActive,
              let window = event.window else { gesture.cancel(); return }
        let point = event.locationInWindow
        switch event.type {
        case .leftMouseDown:
            gesture.mouseDown(windowNumber: window.windowNumber, x: point.x, y: point.y)
        case .leftMouseDragged:
            gesture.mouseDragged()
        case .leftMouseUp:
            guard gesture.mouseUp(windowNumber: window.windowNumber, x: point.x, y: point.y) else { return }
            if window === tourWindow, permitsTourClicks?() != true { return }
            if voice.playClick() { globalClicks += 1 }
            writeReport()
        default: break
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in movementObservers { NotificationCenter.default.removeObserver(observer) }
        movementObservers.removeAll()
        gesture.cancel()
    }

    func stop() {
        observation?.cancel()
        observation = nil
        removeMonitor()
        if let typingMonitor { NSEvent.removeMonitor(typingMonitor) }
        typingMonitor = nil
        voice.stop()
        tourWindow = nil
        permitsTourClicks = nil
        settings = nil
    }

    /// Explicit QA opt-in only; no event contents or identifiers are written.
    private func writeReport() {
        guard let reportURL else { return }
        let report: [String: Any] = [
            "scope": settings?.clickSoundScope.rawValue ?? "unconfigured",
            "globalClicks": globalClicks, "tourClicks": tourClicks,
            "monitorInstalled": monitor != nil,
            "typingScope": settings?.typingSoundScope.rawValue ?? "unconfigured",
            "typingMonitorInstalled": typingMonitor != nil,
            "typingSounds": typingSounds,
            "typingVariations": typingVariations.count,
            "preparedTypingBuffers": voice.preparedTypingBufferCount,
            "clickError": voice.lastClickError as Any? ?? NSNull(),
            "typingError": voice.lastTypingError as Any? ?? NSNull(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }
}
