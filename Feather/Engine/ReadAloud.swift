import AVFoundation
import WebKit

/// Listen to Page (⌥⌘L): reads the article (as reader view extracts it) aloud
/// with the system voice for its language. A banner shows what's being read.
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = ReadAloud()
    weak var state: BrowserState?
    private let synthesizer = AVSpeechSynthesizer()
    private var toast: UUID?
    private(set) var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ tab: Tab, in window: WindowState) {
        if isSpeaking { return stop() }
        guard let webView = tab.webView else { return }
        Task { @MainActor in
            guard let article = await ReaderMode.article(in: webView) else {
                state?.toasts.show("This page doesn't have an article to read aloud.", symbol: "speaker.slash", in: window.id)
                return
            }
            let text = article.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            let utterance = AVSpeechUtterance(string: article.title + ". " + text)
            if let language = article.language, let voice = AVSpeechSynthesisVoice(language: language) { utterance.voice = voice }
            utterance.prefersAssistiveTechnologySettings = true
            isSpeaking = true
            synthesizer.speak(utterance)
            let minutes = max(1, text.split(separator: " ").count / 170)
            toast = state?.toasts.show("Reading “\(article.title)” aloud (about \(minutes) min)", symbol: "waveform",
                                       in: window.id, actions: [
                .init(title: "Pause") { [weak self] in self?.pauseOrResume(in: window) },
                .init(title: "Stop", isPrimary: true) { [weak self] in self?.stop() },
            ], duration: 24 * 3600)
        }
    }

    private func pauseOrResume(in window: WindowState) {
        if synthesizer.isPaused { synthesizer.continueSpeaking() } else { synthesizer.pauseSpeaking(at: .word) }
        // The banner closes when a button is used; show it again with the other choice.
        toast = state?.toasts.show(synthesizer.isPaused ? "Reading paused" : "Reading aloud", symbol: "waveform", in: window.id,
                                   actions: [
            .init(title: synthesizer.isPaused ? "Resume" : "Pause") { [weak self] in self?.pauseOrResume(in: window) },
            .init(title: "Stop", isPrimary: true) { [weak self] in self?.stop() },
        ], duration: 24 * 3600)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() {
        isSpeaking = false
        if let toast { state?.toasts.dismiss(toast) }
        toast = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}
