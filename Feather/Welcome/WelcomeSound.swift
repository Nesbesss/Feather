import AVFoundation
import Observation

/// Music and tap players plus a bounded bank of overlapping keyboard voices.
/// Never changes system volume/output or captures audio.
@Observable @MainActor
final class WelcomeSound: NSObject, AVAudioPlayerDelegate {
    enum Status: String, Sendable {
        case idle, playing, paused, stopped, finished, failed
    }

    private(set) var status: Status = .idle
    private(set) var lastError: String?
    private(set) var lastClickError: String?
    var lastTypingError: String? { typing.lastError }
    private(set) var lastPrepareSucceeded = false
    private(set) var lastPlaySucceeded = false
    private(set) var musicVolume: Float = 0.85
    var isPlaying: Bool { status == .playing && musicPlayer?.isPlaying == true }
    var playbackPosition: TimeInterval { musicPlayer?.currentTime ?? 0 }
    var musicDuration: TimeInterval { musicPlayer?.duration ?? 0 }
    var musicLoopCount: Int { musicPlayer?.numberOfLoops ?? 0 }
    var isClickPlaying: Bool { clickPlayer?.isPlaying == true }
    var isTypingPlaying: Bool { typing.isPlaying }
    var activeTypingVoiceCount: Int { typing.activeVoiceCount }
    var preparedTypingBufferCount: Int { typing.preparedBufferCount }
    var lastTypingSampleID: Int? { typing.lastSampleID }
    var typingEngineIsRunning: Bool { typing.isEngineRunning }

    @ObservationIgnored private let resourceURL: URL?
    @ObservationIgnored private var musicPlayer: AVAudioPlayer?
    @ObservationIgnored private var clickPlayer: AVAudioPlayer?
    @ObservationIgnored private var lastClickTime: TimeInterval?
    @ObservationIgnored private let typing = TypingSoundPlayer()

    nonisolated static let sampleRate = 44_100
    nonisolated static let clickDuration = 0.035
    nonisolated static let clickThrottle = 0.08
    nonisolated private static let clickData = makeClickWave()
    nonisolated static let typingThrottle = TypingSoundDesign.duplicateInterval

    init(resourceURL: URL? = WelcomeSound.bundledMusicURL()) {
        self.resourceURL = resourceURL
        super.init()
    }

    nonisolated static func bundledMusicURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "tour-background", withExtension: "mp3", subdirectory: "Audio")
            ?? bundle.url(forResource: "tour-background", withExtension: "mp3")
    }

    /// Starts or resumes music. Repeated calls while playing do not rewind or
    /// reapply the fade, so a tour step cannot interrupt the background track.
    @discardableResult
    func play() -> Bool {
        if musicPlayer?.isPlaying == true {
            status = .playing
            return true
        }
        lastError = nil
        lastPlaySucceeded = false
        do {
            if musicPlayer == nil {
                lastPrepareSucceeded = false
                guard let resourceURL else {
                    return fail("The tour music is missing from this copy of Feather.")
                }
                let player = try AVAudioPlayer(contentsOf: resourceURL)
                player.numberOfLoops = -1
                player.delegate = self
                musicPlayer = player
                lastPrepareSucceeded = player.prepareToPlay()
                guard lastPrepareSucceeded else {
                    return fail("The tour music could not prepare the current audio output.")
                }
            }
            guard let player = musicPlayer else { return false }
            player.volume = 0
            lastPlaySucceeded = player.play()
            guard lastPlaySucceeded else {
                return fail("The tour music could not start on the current audio output.")
            }
            player.setVolume(musicVolume, fadeDuration: 0.6)
            status = .playing
            return true
        } catch {
            return fail("The tour music could not load: \(error.localizedDescription)")
        }
    }

    /// Activity and mute pauses retain music position; taps never resume later.
    func pause() {
        musicPlayer?.pause()
        clickPlayer?.stop()
        typing.pause()
        if status != .failed { status = .paused }
    }

    /// Finishing the tour resets and releases all voices.
    func stop() {
        musicPlayer?.delegate = nil
        musicPlayer?.stop()
        musicPlayer = nil
        clickPlayer?.delegate = nil
        clickPlayer?.stop()
        clickPlayer = nil
        lastClickTime = nil
        typing.stop()
        status = .stopped
    }

    func setVolume(_ value: Float) {
        musicVolume = value.isFinite ? min(1, max(0, value)) : 0.85
        if musicPlayer?.isPlaying == true { musicPlayer?.setVolume(musicVolume, fadeDuration: 0.15) }
    }

    /// One reusable tap voice, with monotonic throttling for duplicate action
    /// callbacks. It mixes with music instead of restarting or pausing it.
    @discardableResult
    func playClick() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastClickTime, now - lastClickTime < Self.clickThrottle { return false }
        lastClickTime = now
        lastClickError = nil
        do {
            if clickPlayer == nil {
                let player = try AVAudioPlayer(data: Self.clickData)
                player.volume = 0.28
                player.numberOfLoops = 0
                player.delegate = self
                guard player.prepareToPlay() else {
                    lastClickError = "The tour tap could not prepare the current audio output."
                    return false
                }
                clickPlayer = player
            }
            guard let player = clickPlayer else { return false }
            player.currentTime = 0
            let accepted = player.play()
            if !accepted { lastClickError = "The tour tap could not start on the current audio output." }
            return accepted
        } catch {
            lastClickError = "The tour tap could not load: \(error.localizedDescription)"
            return false
        }
    }

    /// Physical-key identity selects real switch takes; every key rotates
    /// through four variations. Different keys overlap instead of cutting tails.
    /// Text never reaches the audio engine.
    @discardableResult
    func playTyping(keyCode: UInt16 = 0) -> Bool { typing.play(keyCode: keyCode) }

    @discardableResult
    func prepareTyping() -> Bool { typing.prepare() }

    func stopTyping() { typing.stop() }

    @discardableResult
    private func fail(_ message: String) -> Bool {
        stop()
        lastError = message
        status = .failed
        return false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finishedPlayer = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let current = self.clickPlayer, ObjectIdentifier(current) == finishedPlayer {
                if !flag { self.lastClickError = "The tour tap stopped before it finished." }
                return
            }
            guard let current = self.musicPlayer, ObjectIdentifier(current) == finishedPlayer else { return }
            if flag { self.status = .finished }
            else { self.fail("The tour music stopped before it finished.") }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let failedPlayer = ObjectIdentifier(player)
        let message = error?.localizedDescription ?? "The audio could not be decoded."
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let current = self.clickPlayer, ObjectIdentifier(current) == failedPlayer {
                self.lastClickError = "The tour tap could not play: \(message)"
                current.delegate = nil
                self.clickPlayer = nil
                return
            }
            guard let current = self.musicPlayer, ObjectIdentifier(current) == failedPlayer else { return }
            self.fail("The tour music could not play: \(message)")
        }
    }

    /// An original 35 ms soft tap: damped tone with a little filtered texture,
    /// normalized with headroom and zero-valued edges to avoid a sharp click.
    nonisolated static func makeClickWave() -> Data {
        let count = Int(Double(sampleRate) * clickDuration)
        var values = [Double](repeating: 0, count: count)
        var peak = 0.0
        var seed: UInt32 = 0xF347_4E12
        var filtered = 0.0
        for frame in 0..<count {
            let t = Double(frame) / Double(sampleRate)
            seed = 1_664_525 &* seed &+ 1_013_904_223
            let noise = Double(seed) / Double(UInt32.max) * 2 - 1
            filtered += 0.24 * (noise - filtered)
            let attack = min(1, t / 0.0025)
            let release = min(1, (Double(count - 1 - frame) / Double(sampleRate)) / 0.012)
            let envelope = attack * attack * exp(-105 * t) * release * release
            let tone = sin(2 * .pi * (1_100 * t - 6_000 * t * t))
            let value = (0.86 * tone + 0.14 * filtered) * envelope
            values[frame] = value
            peak = max(peak, abs(value))
        }
        var samples = Data(capacity: count * 2)
        let gain = peak > 0 ? 0.38 * Double(Int16.max) / peak : 0
        for value in values {
            var little = Int16((value * gain).rounded()).littleEndian
            withUnsafeBytes(of: &little) { samples.append(contentsOf: $0) }
        }
        var wave = Data(capacity: 44 + samples.count)
        func text(_ value: String) { wave.append(contentsOf: value.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) }
        }
        text("RIFF"); word(UInt32(36 + samples.count)); text("WAVE")
        text("fmt "); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(sampleRate)); word(UInt32(sampleRate * 2))
        word(UInt16(2)); word(UInt16(16))
        text("data"); word(UInt32(samples.count)); wave.append(samples)
        return wave
    }

}
