import AVFoundation
import XCTest

final class WelcomeSoundTests: XCTestCase {
    func testClickHeaderAndLengthDescribeShortMonoPCM() {
        let wave = WelcomeSound.makeClickWave()
        XCTAssertEqual(String(data: wave[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wave[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wave[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(word(wave, 20, count: 2), 1)
        XCTAssertEqual(word(wave, 22, count: 2), 1)
        XCTAssertEqual(word(wave, 24, count: 4), UInt32(WelcomeSound.sampleRate))
        XCTAssertEqual(word(wave, 34, count: 2), 16)
        XCTAssertEqual(String(data: wave[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(Int(word(wave, 40, count: 4)), wave.count - 44)
        XCTAssertEqual(Int(word(wave, 4, count: 4)), wave.count - 8)
        XCTAssertEqual(wave.count - 44, Int(Double(WelcomeSound.sampleRate) * WelcomeSound.clickDuration) * 2)
    }

    func testOriginalClickHasHeadroomAndClickFreeEdges() {
        let wave = WelcomeSound.makeClickWave()
        let values = stride(from: 44, to: wave.count, by: 2).map {
            Double(Int16(bitPattern: UInt16(word(wave, $0, count: 2)))) / Double(Int16.max)
        }
        let peak = values.map(abs).max() ?? 0
        let rms = sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))
        XCTAssertEqual(peak, 0.38, accuracy: 0.001)
        XCTAssertGreaterThan(rms, 0.04)
        XCTAssertLessThan(rms, 0.2)
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 0)
        XCTAssertEqual(wave, WelcomeSound.makeClickWave())
    }

    func testBundledSuppliedMusicDecodesWithoutPlayback() throws {
        let url = try XCTUnwrap(WelcomeSound.bundledMusicURL(in: Bundle(for: Self.self)))
        let player = try AVAudioPlayer(contentsOf: url)
        XCTAssertEqual(player.numberOfChannels, 2)
        XCTAssertEqual(player.duration, 142.248, accuracy: 0.1)
        XCTAssertFalse(player.isPlaying)
    }

    func testOriginalClickDecodesWithoutPlayback() throws {
        let player = try AVAudioPlayer(data: WelcomeSound.makeClickWave())
        XCTAssertEqual(player.numberOfChannels, 1)
        XCTAssertEqual(player.duration, WelcomeSound.clickDuration, accuracy: 1 / Double(WelcomeSound.sampleRate))
        XCTAssertFalse(player.isPlaying)
    }

    func testMissingTypingBankFailsWithoutStartingAudio() {
        MainActor.assumeIsolated {
            let typing = TypingSoundPlayer(bankDirectory: nil)
            XCTAssertFalse(typing.prepare())
            XCTAssertFalse(typing.play(keyCode: 0))
            XCTAssertNotNil(typing.lastError)
            XCTAssertFalse(typing.isPlaying)
            XCTAssertEqual(typing.preparedBufferCount, 0)
        }
    }

    func testMissingMusicReportsFailureWithoutCrashing() {
        MainActor.assumeIsolated {
            let sound = WelcomeSound(resourceURL: nil)
            XCTAssertFalse(sound.play())
            XCTAssertEqual(sound.status, .failed)
            XCTAssertNotNil(sound.lastError)
            XCTAssertFalse(sound.isPlaying)
            sound.stop()
            XCTAssertEqual(sound.status, .stopped)
            XCTAssertEqual(sound.playbackPosition, 0)
        }
    }

    func testVolumeClampsWithoutStartingPlayback() {
        MainActor.assumeIsolated {
            let sound = WelcomeSound(resourceURL: nil)
            sound.setVolume(2)
            XCTAssertEqual(sound.musicVolume, 1)
            sound.setVolume(-1)
            XCTAssertEqual(sound.musicVolume, 0)
            sound.setVolume(.nan)
            XCTAssertEqual(sound.musicVolume, 0.85)
            XCTAssertFalse(sound.isPlaying)
        }
    }

    func testMutedOrInactiveStateDoesNotStartEitherVoice() {
        MainActor.assumeIsolated {
            let sound = WelcomeSound(resourceURL: nil)
            let playback = WelcomePlaybackState(sound: sound)
            XCTAssertFalse(playback.playClick())
            playback.isMuted = true
            playback.live = true
            XCTAssertFalse(playback.playClick())
            XCTAssertFalse(sound.isPlaying)
            XCTAssertFalse(sound.isClickPlaying)
            XCTAssertFalse(sound.isTypingPlaying)
            playback.live = false
            playback.isMuted = false
            XCTAssertFalse(playback.playClick())
            XCTAssertNil(sound.lastError)
        }
    }

    private func word(_ data: Data, _ offset: Int, count: Int) -> UInt32 {
        (0..<count).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
}
