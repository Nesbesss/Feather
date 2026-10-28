import Foundation

/// Physical-key character and variation only. Never receives or retains text.
nonisolated enum TypingSoundDesign {
    enum Family: Int, CaseIterable, Sendable {
        case left, middle, right, space, delete, punctuation
    }
    struct Profile: Sendable, Equatable {
        let family: Family
        let rate: Double
        let pan: Float
        let gain: Float
    }
    static let variantCount = 4
    static let duplicateInterval = 0.012
    static let gain: Float = 0.32

    static func resourceFileName(family: Family, variant: Int) -> String {
        "family\(family.rawValue)-v\(variant % variantCount)"
    }

    static func profile(keyCode: UInt16) -> Profile {
        let family: Family
        switch keyCode {
        case 49: family = .space
        case 51, 117: family = .delete
        case 24, 27, 30, 33, 39, 41, 42, 43, 44, 47, 50: family = .punctuation
        case 0, 1, 2, 6, 7, 8, 12, 13, 14, 18, 19, 20: family = .left
        case 3, 5, 9, 11, 15, 17, 21, 23: family = .middle
        default: family = .right
        }
        // Small stable differences in cap/case resonance. Space and Delete
        // already have separate recordings/voicing; avoid cartoon pitch shifts.
        let identity = Int(keyCode & 127)
        let rate = 0.967 + Double((identity * 37 + 11) % 67) / 1_000
        let gain = Float(0.94 + Double((identity * 17 + 5) % 13) / 100)
        let pan: Float
        switch family {
        case .left: pan = -0.07
        case .middle, .space: pan = 0
        case .right: pan = 0.07
        case .delete, .punctuation: pan = 0.09
        }
        return Profile(family: family, rate: rate, pan: pan, gain: gain)
    }
}

nonisolated struct TypingSoundChoice: Sendable {
    let family: TypingSoundDesign.Family
    let variant: Int
    let profile: TypingSoundDesign.Profile
    var sampleID: Int { family.rawValue * TypingSoundDesign.variantCount + variant }
}

/// Fixed-size per-key round robin. Distinct keys are never globally throttled,
/// so chords and quick alternation retain all their attacks.
nonisolated struct TypingSoundSelection: Sendable {
    private var steps = [UInt8](repeating: 0, count: 128)
    private var times = [TimeInterval?](repeating: nil, count: 128)

    mutating func next(keyCode: UInt16, at time: TimeInterval) -> TypingSoundChoice? {
        guard time.isFinite else { return nil }
        let key = Int(keyCode & 127)
        if let previous = times[key], time - previous < TypingSoundDesign.duplicateInterval { return nil }
        times[key] = time
        let profile = TypingSoundDesign.profile(keyCode: keyCode)
        // 0,2,1,3 avoids the conspicuous up/down pitch cycle of sequential takes.
        let order = [0, 2, 1, 3]
        let variant = order[(key * 3 + Int(steps[key])) % order.count]
        steps[key] = (steps[key] + 1) % 4
        return TypingSoundChoice(family: profile.family, variant: variant, profile: profile)
    }

    mutating func reset() {
        steps = [UInt8](repeating: 0, count: 128)
        times = [TimeInterval?](repeating: nil, count: 128)
    }
}

/// Bounded overlap: prefer an idle voice; on saturation steal the oldest tail.
/// Nothing is queued behind an earlier keystroke.
nonisolated struct TypingVoicePool: Sendable {
    private var ends: [TimeInterval]
    init(capacity: Int) { ends = Array(repeating: -.infinity, count: max(1, min(8, capacity))) }

    mutating func reserve(at time: TimeInterval, duration: TimeInterval) -> Int {
        let index = ends.firstIndex(where: { $0 <= time })
            ?? ends.indices.min(by: { ends[$0] < ends[$1] }) ?? 0
        ends[index] = time + max(0, duration)
        return index
    }
    func activeCount(at time: TimeInterval) -> Int { ends.filter { $0 > time }.count }
    mutating func reset() { ends = Array(repeating: -.infinity, count: ends.count) }
}
