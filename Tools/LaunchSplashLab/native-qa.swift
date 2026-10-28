import AppKit
import CryptoKit
import SwiftUI

/// Compiles the actual production splash and supplies no browser/profile data.
/// All windows are temporary local fixtures; no user preferences are modified.
@MainActor final class SplashQA {
    let root: URL
    let output: URL
    var checks: [String: Bool] = [:]
    var observations: [String: Any] = [:]
    var windows: [NSWindow] = []
    var controllers: [LaunchSplashController] = []
    var finished = false
    let started = Date()

    init(root: URL, output: URL) { self.root = root; self.output = output }
    func sleep(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    func fixture(width: CGFloat = 800, height: CGFloat = 520) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Feather launch splash compatibility check"
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let label = NSTextField(labelWithString: "Restored browser fixture")
        label.frame = NSRect(x: 30, y: 30, width: 300, height: 30)
        container.addSubview(label)
        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        return (window, container)
    }

    func draw(elapsed: Double, size: CGSize, dark: Bool, reduced: Bool, file: URL, scale: CGFloat = 2) throws {
        let renderer = ImageRenderer(content: LaunchSplashView(elapsed: elapsed, reduceMotion: reduced)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { throw failure("SwiftUI could not render \(file.lastPathComponent)") }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("PNG encoding failed") }
        try png.write(to: file)
    }

    func contactSheet(_ paths: [URL], times: [Double]) throws {
        let width = 1600, height = 500
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw failure("Contact sheet context unavailable") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(srgbRed: 0.94, green: 0.96, blue: 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, path) in paths.enumerated() {
            let x = CGFloat(index % 5) * 320
            let y = CGFloat(1 - index / 5) * 250
            NSImage(contentsOf: path)?.draw(in: NSRect(x: x, y: y + 30, width: 320, height: 210))
            let text = String(format: "%.2f s", times[index]) as NSString
            text.draw(at: NSPoint(x: x + 12, y: y + 8), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.darkGray])
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("flight-contact-sheet.png"))
    }

    func render() throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let feather = NSImage(named: NSImage.Name("FeatherMark")), feather.size.width > 0 else {
            throw failure("The production FeatherMark asset is missing from the fixture bundle")
        }
        checks["productionFeatherAssetResolves"] = true
        let times = [0.0, 0.22, 0.45, 0.70, 0.95, 1.15, 1.40, 1.65, 1.85, 2.2]
        var paths: [URL] = []
        for (index, time) in times.enumerated() {
            let file = output.appendingPathComponent(String(format: "flight-%02d.png", index))
            try draw(elapsed: time, size: CGSize(width: 640, height: 420), dark: false, reduced: false, file: file)
            paths.append(file)
        }
        try contactSheet(paths, times: times)
        try draw(elapsed: 1.05, size: CGSize(width: 1280, height: 820), dark: false, reduced: false, file: output.appendingPathComponent("flight-large-light.png"))
        try draw(elapsed: LaunchSplashMotion.duration, size: CGSize(width: 1280, height: 820), dark: true, reduced: false, file: output.appendingPathComponent("rest-large-dark.png"))
        try draw(elapsed: 0, size: CGSize(width: 640, height: 420), dark: false, reduced: true, file: output.appendingPathComponent("reduced-motion-still.png"))
        let frames = output.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for index in 0..<Int(ceil((LaunchSplashMotion.duration + LaunchSplashMotion.fadeDuration) * 60)) {
            let elapsed = min(LaunchSplashMotion.duration, Double(index) / 60)
            let file = frames.appendingPathComponent(String(format: "%04d.png", index))
            try draw(elapsed: elapsed, size: CGSize(width: 960, height: 600), dark: false, reduced: false, file: file, scale: 1)
        }
        checks["productionArtworkRendersAtMinimumAndLargeSizes"] = true
        observations["renderedFrameCount"] = Int(ceil((LaunchSplashMotion.duration + LaunchSplashMotion.fadeDuration) * 60))
        print("Rendered launch contact sheet: \(output.appendingPathComponent("flight-contact-sheet.png").path)")
        fflush(stdout)
    }

    func run() async throws {
        try render()
        do {
            let (window, container) = fixture()
            var completions = 0
            let splash = LaunchSplashController(in: container, window: window, reduceMotion: false, activity: { true })
            controllers.append(splash)
            checks["installAttachesOverlayBeforeStart"] = splash.isShowing && container.subviews.count == 2
            splash.start { completions += 1 }
            await sleep(LaunchSplashMotion.duration + LaunchSplashMotion.fadeDuration + 0.3)
            checks["automaticCompletionRemovesOverlay"] = !splash.isShowing && container.subviews.count == 1
            checks["automaticCompletionFiresOnce"] = completions == 1
            let stoppedElapsed = splash.elapsed
            splash.dismiss()
            splash.cancel()
            await sleep(0.10)
            checks["finishedControllerStaysStopped"] = splash.elapsed == stoppedElapsed && completions == 1
            window.orderOut(nil)
        }
        do {
            let (window, container) = fixture()
            var completions = 0
            let splash = LaunchSplashController(in: container, window: window, reduceMotion: false, activity: { true })
            controllers.append(splash)
            splash.start { completions += 1 }
            await sleep(0.08)
            splash.dismiss()
            splash.dismiss()
            await sleep(LaunchSplashMotion.fadeDuration + 0.15)
            checks["dismissCompletesExactlyOnce"] = completions == 1 && !splash.isShowing && container.subviews.count == 1
            window.orderOut(nil)
        }
        do {
            let (window, container) = fixture()
            var completions = 0
            let splash = LaunchSplashController(in: container, window: window, reduceMotion: false, activity: { true })
            controllers.append(splash)
            splash.start { completions += 1 }
            splash.dismiss(afterCurrentEvent: true)
            checks["tabClosePathDefersFollowUpUntilAfterEvent"] = completions == 0 && !splash.isShowing
            await sleep(0.08)
            checks["survivingWindowReleasesSplashAndCompletes"] = completions == 1 && container.subviews.count == 1
            window.orderOut(nil)
        }
        do {
            let (window, container) = fixture()
            var completions = 0
            let splash = LaunchSplashController(in: container, window: window, reduceMotion: false, activity: { true })
            controllers.append(splash)
            splash.start { completions += 1 }
            splash.dismiss(afterCurrentEvent: true)
            window.close()
            await sleep(0.08)
            checks["actualWindowCloseCancelsDeferredFollowUp"] = completions == 0 && !splash.isShowing
        }
        do {
            let (window, container) = fixture()
            var completions = 0
            let splash = LaunchSplashController(in: container, window: window, reduceMotion: false, activity: { true })
            controllers.append(splash)
            splash.start { completions += 1 }
            await sleep(0.08)
            splash.cancel()
            await sleep(LaunchSplashMotion.fadeDuration + 0.10)
            checks["cancelRemovesWithoutCompletion"] = completions == 0 && !splash.isShowing && container.subviews.count == 1
            window.orderOut(nil)
        }
        do {
            let (window, container) = fixture()
            var completions = 0
            let splash = LaunchSplashController(in: container, window: window, reduceMotion: false, activity: { true })
            controllers.append(splash)
            splash.start { completions += 1 }
            window.close()
            await sleep(0.15)
            checks["windowCloseCancelsWithoutCompletion"] = completions == 0 && !splash.isShowing && container.subviews.count == 1
        }
        do {
            let (window, container) = fixture()
            var live = true
            var completions = 0
            let splash = LaunchSplashController(in: container, window: window, reduceMotion: false, activity: { live })
            controllers.append(splash)
            splash.start { completions += 1 }
            await sleep(0.12)
            live = false
            splash.updateActivity()
            await sleep(0.05)
            let paused = splash.elapsed
            await sleep(0.18)
            checks["inactiveClockDoesNotAdvance"] = abs(splash.elapsed - paused) < 0.005 && completions == 0
            live = true
            splash.updateActivity()
            await sleep(0.15)
            checks["activeClockResumesFromCarriedTime"] = splash.elapsed > paused + 0.06 && splash.elapsed < paused + 0.3
            window.setContentSize(NSSize(width: 640, height: 420))
            container.layoutSubtreeIfNeeded()
            await sleep(0.05)
            checks["overlayTracksWindowResize"] = container.subviews.last?.frame.size == container.bounds.size
            splash.cancel()
            window.orderOut(nil)
        }
        do {
            let (window, container) = fixture()
            var completions = 0
            let splash = LaunchSplashController(in: container, window: window, reduceMotion: true, activity: { true })
            controllers.append(splash)
            splash.start { completions += 1 }
            await sleep(LaunchSplashMotion.reducedDuration + LaunchSplashMotion.fadeDuration + 0.20)
            checks["reducedMotionCompletesPromptly"] = completions == 1 && !splash.isShowing && container.subviews.count == 1
            window.orderOut(nil)
        }
        do {
            let (window, container) = fixture()
            var completions = 0
            let splash = LaunchSplashController(in: container, window: window, reduceMotion: false, activity: { false })
            controllers.append(splash)
            splash.start { completions += 1 }
            await sleep(5.25)
            checks["inactiveDeadlineCannotBlockBrowserIndefinitely"] = completions == 1 && !splash.isShowing && splash.elapsed == 0
            window.orderOut(nil)
        }
        do {
            let (window, container) = fixture()
            var completions = 0
            let splash = LaunchSplashController(in: container, window: window, reduceMotion: false, activity: { true })
            controllers.append(splash)
            splash.cancel()
            splash.start { completions += 1 }
            await sleep(0.08)
            checks["cancelledBeforeStartCannotAttachOrRestart"] = completions == 0 && !splash.isShowing && container.subviews.count == 1
            window.orderOut(nil)
        }
        let files = ["LaunchSplashMotion.swift", "LaunchSplashView.swift", "LaunchSplashController.swift"]
        observations["productionSHA256"] = Dictionary(uniqueKeysWithValues: try files.map { name in
            let data = try Data(contentsOf: root.appendingPathComponent("Feather/Welcome/" + name))
            return (name, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        })
    }

    func finish(error: Error? = nil) {
        guard !finished else { return }; finished = true
        controllers.forEach { $0.cancel() }
        windows.forEach { $0.orderOut(nil) }
        if let error { observations["error"] = error.localizedDescription; checks["harnessCompletes"] = false }
        let failures = checks.values.filter { !$0 }.count
        let report: [String: Any] = ["allPassed": failures == 0, "passedCount": checks.count - failures,
            "failedCount": failures, "checks": checks, "observations": observations,
            "elapsedSeconds": Date().timeIntervalSince(started),
            "scope": "Exact production native splash controller, motion, and view; temporary AppKit windows with injected activity; artwork rendered offline; no user browser, session, preferences, or network accessed."]
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-qa.json"), options: .atomic)
        } catch { fputs("Failed writing report: \(error)\n", stderr); exit(2) }
        print("Launch splash native QA: \(checks.count - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
    func failure(_ message: String) -> NSError { NSError(domain: "LaunchSplashQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main struct LaunchSplashQAMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { fputs("Expected repository path and output directory\n", stderr); exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let harness = SplashQA(root: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2]))
        Task { @MainActor in
            do { try await harness.run(); harness.finish() }
            catch { harness.finish(error: error) }
        }
        withExtendedLifetime(harness) { app.run() }
    }
}
