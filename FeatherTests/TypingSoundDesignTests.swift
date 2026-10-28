import AVFoundation
import XCTest

final class TypingSoundDesignTests: XCTestCase {
    func testPhysicalKeyProfilesStayStableAndHaveDistinctKeyboardPositions() {
        let left = TypingSoundDesign.profile(keyCode: 0)   // A
        let middle = TypingSoundDesign.profile(keyCode: 5) // G
        let right = TypingSoundDesign.profile(keyCode: 37) // L
        XCTAssertLessThan(left.pan, middle.pan)
        XCTAssertLessThan(middle.pan, right.pan)

        for key in UInt16(0)..<128 {
            let first = TypingSoundDesign.profile(keyCode: key)
            let again = TypingSoundDesign.profile(keyCode: key)
            XCTAssertEqual(first.family, again.family)
            XCTAssertEqual(first.rate, again.rate)
            XCTAssertEqual(first.pan, again.pan)
            XCTAssertEqual(first.gain, again.gain)
            XCTAssertTrue(first.rate.isFinite)
            XCTAssertGreaterThan(first.rate, 0.5)
            XCTAssertLessThan(first.rate, 1.5)
            XCTAssertTrue(first.pan.isFinite)
            XCTAssertTrue((-1...1).contains(first.pan))
            XCTAssertTrue(first.gain.isFinite)
            XCTAssertGreaterThan(first.gain, 0)
            XCTAssertLessThanOrEqual(first.gain, 1.1)
        }
    }

    func testSpaceAndDeleteHaveDedicatedFamilies() {
        XCTAssertEqual(TypingSoundDesign.profile(keyCode: 49).family, .space)
        XCTAssertEqual(TypingSoundDesign.profile(keyCode: 51).family, .delete)
        XCTAssertEqual(TypingSoundDesign.profile(keyCode: 117).family, .delete)
        XCTAssertNotEqual(TypingSoundDesign.profile(keyCode: 49).family,
                          TypingSoundDesign.profile(keyCode: 0).family)
    }

    func testOneKeyCyclesAllFourVariantsWithoutChangingItsIdentity() throws {
        XCTAssertEqual(TypingSoundDesign.variantCount, 4)
        let key: UInt16 = 9
        let profile = TypingSoundDesign.profile(keyCode: key)
        var selection = TypingSoundSelection()
        var variants: [Int] = []
        for index in 0..<8 {
            let choice = try XCTUnwrap(selection.next(keyCode: key, at: Double(index) * 0.02))
            variants.append(choice.variant)
            XCTAssertEqual(choice.family, profile.family)
            XCTAssertEqual(choice.profile.rate, profile.rate)
            XCTAssertEqual(choice.profile.pan, profile.pan)
            XCTAssertEqual(choice.profile.gain, profile.gain)
        }
        XCTAssertEqual(Set(variants.prefix(4)).count, 4)
        XCTAssertEqual(Array(variants.prefix(4)), Array(variants.suffix(4)))
        for pair in zip(variants, variants.dropFirst()) { XCTAssertNotEqual(pair.0, pair.1) }
    }

    func testDuplicateProtectionDoesNotDropFastDifferentKeys() throws {
        var selection = TypingSoundSelection()
        XCTAssertNotNil(selection.next(keyCode: 0, at: 0))
        var withoutDuplicates = selection
        XCTAssertNil(selection.next(keyCode: 0, at: 0.011))
        XCTAssertNotNil(selection.next(keyCode: 1, at: 0.011))
        XCTAssertNotNil(selection.next(keyCode: 2, at: 0.011))
        let next = try XCTUnwrap(selection.next(keyCode: 0, at: 0.012))
        let baseline = try XCTUnwrap(withoutDuplicates.next(keyCode: 0, at: 0.012))
        XCTAssertEqual(next.variant, baseline.variant, "A suppressed duplicate must not consume a variant.")
    }

    func testSelectionUsesBoundedKeySlotsAndResetRestartsTheSequence() throws {
        var selection = TypingSoundSelection()
        let initial = try XCTUnwrap(selection.next(keyCode: 7, at: 1))
        XCTAssertNil(selection.next(keyCode: 135, at: 1), "Unknown key codes share their masked slot.")
        XCTAssertNotNil(selection.next(keyCode: .max, at: 1))
        XCTAssertNil(selection.next(keyCode: 127, at: 1))
        selection.reset()
        let restarted = try XCTUnwrap(selection.next(keyCode: 7, at: 1))
        XCTAssertEqual(restarted.variant, initial.variant)
        XCTAssertEqual(restarted.family, initial.family)
    }

    func testEightKeyChordOverlapsAndTheNextKeyStealsTheOldestVoice() {
        var pool = TypingVoicePool(capacity: 8)
        let slots = (0..<8).map { pool.reserve(at: Double($0) * 0.001, duration: 1) }
        XCTAssertEqual(Set(slots).count, 8)
        XCTAssertEqual(pool.activeCount(at: 0.008), 8)
        XCTAssertEqual(pool.reserve(at: 0.008, duration: 1), slots[0])
        XCTAssertEqual(pool.reserve(at: 0.009, duration: 1), slots[1])
        XCTAssertEqual(pool.activeCount(at: 0.01), 8)
    }

    func testPoolReusesFinishedVoiceBeforeInterruptingAnotherAndResetClearsIt() {
        var pool = TypingVoicePool(capacity: 2)
        let short = pool.reserve(at: 0, duration: 0.05)
        let long = pool.reserve(at: 0.001, duration: 1)
        XCTAssertNotEqual(short, long)
        XCTAssertEqual(pool.activeCount(at: 0.06), 1)
        XCTAssertEqual(pool.reserve(at: 0.06, duration: 0.1), short)
        XCTAssertEqual(pool.activeCount(at: 0.07), 2)
        pool.reset()
        XCTAssertEqual(pool.activeCount(at: 0.07), 0)
        XCTAssertEqual(pool.reserve(at: 0.07, duration: 0.1), short)
    }

    func testPoolCapsOversizedCapacityAndCannotGrowDuringABurst() {
        var pool = TypingVoicePool(capacity: 128)
        let slots = (0..<128).map { pool.reserve(at: Double($0) * 0.0001, duration: 1) }
        XCTAssertEqual(Set(slots).count, 8)
        XCTAssertEqual(pool.activeCount(at: 0.02), 8)
        XCTAssertEqual(pool.activeCount(at: 2), 0)
    }

    func testAllTwentyFourBundledVariantsDecodeAndContainDifferentAudio() throws {
        let bundle = Bundle(for: Self.self)
        var fileNames = Set<String>()
        var decodedVariants = Set<Data>()
        for family in TypingSoundDesign.Family.allCases {
            var familyVariants = Set<Data>()
            for variant in 0..<TypingSoundDesign.variantCount {
                let name = TypingSoundDesign.resourceFileName(family: family, variant: variant)
                XCTAssertTrue(fileNames.insert(name).inserted)
                let url = try XCTUnwrap(
                    bundle.url(forResource: name, withExtension: "wav", subdirectory: "Audio/Typing")
                        ?? bundle.url(forResource: name, withExtension: "wav", subdirectory: "Audio/typing")
                        ?? bundle.url(forResource: name, withExtension: "wav", subdirectory: "Typing")
                        ?? bundle.url(forResource: name, withExtension: "wav"),
                    "Missing bundled keyboard sound \(name).wav")
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                let duration = Double(file.length) / file.processingFormat.sampleRate
                XCTAssertEqual(file.processingFormat.channelCount, 1)
                XCTAssertGreaterThan(duration, 0.02)
                XCTAssertLessThanOrEqual(duration, 0.16)
                guard duration <= 0.16, file.length > 0 else { continue }
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                          frameCapacity: AVAudioFrameCount(file.length)))
                try file.read(into: buffer)
                XCTAssertEqual(Int64(buffer.frameLength), file.length)
                let channel = try XCTUnwrap(buffer.floatChannelData?[0])
                let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
                XCTAssertTrue(samples.allSatisfy(\.isFinite))
                let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                XCTAssertGreaterThan(peak, 0.001, "The sample must contain non-silent audio.")
                XCTAssertLessThan(peak, 0.99, "Leave headroom for overlapping keys.")
                XCTAssertLessThan(abs(try XCTUnwrap(samples.first)), 0.01)
                XCTAssertLessThan(abs(try XCTUnwrap(samples.last)), 0.01)
                let pcm = Data(bytes: channel, count: samples.count * MemoryLayout<Float>.size)
                familyVariants.insert(pcm)
                decodedVariants.insert(pcm)
            }
            XCTAssertEqual(familyVariants.count, TypingSoundDesign.variantCount,
                           "Round-robin variants must contain different decoded audio, not just different headers.")
        }
        XCTAssertEqual(fileNames.count, 24)
        XCTAssertEqual(decodedVariants.count, 24)
    }
}
