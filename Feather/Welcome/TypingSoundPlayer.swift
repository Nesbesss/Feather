import AVFoundation
import Accelerate

/// Shared decoded buffers and eight overlapping voices. Audio decoding and
/// key-specific resampling happen once when a sound scope is enabled.
@MainActor
final class TypingSoundPlayer {
    static let voiceLimit = 8
    private(set) var lastError: String?
    private(set) var lastSampleID: Int?
    private(set) var acceptedCount = 0
    private(set) var preparedBufferCount = 0
    private var engine: AVAudioEngine?
    private var voices: [AVAudioPlayerNode] = []
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private var pool = TypingVoicePool(capacity: voiceLimit)
    private var selection = TypingSoundSelection()
    private var idleWork: DispatchWorkItem?
    private var configurationObserver: NSObjectProtocol?
    private let bankDirectory: URL?
    var isEngineRunning: Bool { engine?.isRunning == true }
    var isPlaying: Bool { engine?.isRunning == true && pool.activeCount(at: ProcessInfo.processInfo.systemUptime) > 0 }
    var activeVoiceCount: Int { pool.activeCount(at: ProcessInfo.processInfo.systemUptime) }

    init(bankDirectory: URL? = TypingSoundPlayer.bundledDirectory()) { self.bankDirectory = bankDirectory }

    nonisolated static func bundledDirectory(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "Typing", withExtension: nil, subdirectory: "Audio")
    }

    @discardableResult
    func prepare() -> Bool {
        if engine != nil { return true }
        lastError = nil
        do {
            guard let bankDirectory,
                  let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
                throw CocoaError(.fileNoSuchFile)
            }
            var takes: [Int: AVAudioPCMBuffer] = [:]
            for family in TypingSoundDesign.Family.allCases {
                for variant in 0..<TypingSoundDesign.variantCount {
                    let name = TypingSoundDesign.resourceFileName(family: family, variant: variant)
                    let file = try AVAudioFile(forReading: bankDirectory.appendingPathComponent(name + ".wav"))
                    guard file.length > 0, file.length <= 11_025,
                          file.processingFormat.sampleRate == format.sampleRate,
                          file.processingFormat.channelCount == 1,
                          let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try file.read(into: pcm)
                    takes[family.rawValue * TypingSoundDesign.variantCount + variant] = pcm
                }
            }
            var decoded: [Int: AVAudioPCMBuffer] = [:]
            for key in UInt16(0)..<128 {
                let profile = TypingSoundDesign.profile(keyCode: key)
                for variant in 0..<TypingSoundDesign.variantCount {
                    let id = profile.family.rawValue * TypingSoundDesign.variantCount + variant
                    guard let source = takes[id], let input = source.floatChannelData?[0] else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let frames = max(2, Int(Double(source.frameLength) / profile.rate))
                    guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                          let output = pcm.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
                    pcm.frameLength = AVAudioFrameCount(frames)
                    var positions = [Float](repeating: 0, count: frames)
                    var start: Float = 0
                    var increment = Float(profile.rate)
                    var minimum: Float = 0
                    // vDSP interpolation reads b+1 even for an integer index.
                    var maximum = Float(source.frameLength - 1) - 0.001
                    positions.withUnsafeMutableBufferPointer { indices in
                        guard let positions = indices.baseAddress else { return }
                        vDSP_vramp(&start, &increment, positions, 1, vDSP_Length(frames))
                        vDSP_vclip(positions, 1, &minimum, &maximum, positions, 1, vDSP_Length(frames))
                        vDSP_vlint(input, positions, 1, output, 1, vDSP_Length(frames), vDSP_Length(source.frameLength))
                    }
                    output[0] = 0
                    output[frames - 1] = 0
                    decoded[Int(key) * TypingSoundDesign.variantCount + variant] = pcm
                }
            }
            let audio = AVAudioEngine()
            var nodes: [AVAudioPlayerNode] = []
            for _ in 0..<Self.voiceLimit {
                let node = AVAudioPlayerNode()
                audio.attach(node)
                audio.connect(node, to: audio.mainMixerNode, format: format)
                nodes.append(node)
            }
            audio.prepare()
            buffers = decoded
            preparedBufferCount = decoded.count
            voices = nodes
            engine = audio
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main
            ) { [weak self, weak audio] _ in
                MainActor.assumeIsolated {
                    guard let self, self.engine === audio else { return }
                    // Output devices can change their stream format. Rebuild
                    // the graph on the next key rather than reuse stale nodes.
                    self.stop()
                }
            }
            return true
        } catch {
            lastError = "The typing sounds could not prepare: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func play(keyCode: UInt16) -> Bool {
        guard prepare(), let engine else { return false }
        do {
            if !engine.isRunning { try engine.start() }
            let now = ProcessInfo.processInfo.systemUptime
            guard let choice = selection.next(keyCode: keyCode, at: now),
                  let buffer = buffers[Int(keyCode & 127) * TypingSoundDesign.variantCount + choice.variant] else { return false }
            idleWork?.cancel()
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            let index = pool.reserve(at: ProcessInfo.processInfo.systemUptime, duration: duration)
            let voice = voices[index]
            voice.stop()
            voice.volume = TypingSoundDesign.gain * choice.profile.gain
            voice.pan = choice.profile.pan
            voice.scheduleBuffer(buffer)
            voice.play()
            lastSampleID = choice.sampleID
            acceptedCount += 1
            lastError = nil
            // No continuously running audio graph during idle browsing. A single
            // cancellable one-shot lets the final natural tail finish first.
            let work = DispatchWorkItem { [weak self] in
                self?.engine?.pause()
                self?.pool.reset()
            }
            idleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.35, duration + 0.05), execute: work)
            return true
        } catch {
            stop()
            lastError = "The typing sounds could not start: \(error.localizedDescription)"
            return false
        }
    }

    func pause() {
        idleWork?.cancel()
        idleWork = nil
        for voice in voices { voice.stop() }
        engine?.pause()
        pool.reset()
        selection.reset()
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        pause()
        engine?.stop()
        engine = nil
        voices.removeAll()
        buffers.removeAll()
        preparedBufferCount = 0
    }
}
