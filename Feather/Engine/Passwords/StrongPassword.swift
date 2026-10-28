import Foundation

/// Generates passwords in Apple's style, `abcdef-ghijkm-n2pqrs`: easy to read
/// aloud, 71+ bits of entropy, with an uppercase letter and a digit so strict
/// password rules accept it.
nonisolated enum StrongPassword {
    /// No look-alikes (0/o, 1/l/i).
    private static let lower = Array("abcdefghjkmnpqrstuvwxyz")
    private static let digits = Array("23456789")

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        var chars = (0..<18).map { _ in lower.randomElement(using: &generator)! }
        let upperIndex = Int.random(in: 0..<18, using: &generator)
        var digitIndex = Int.random(in: 0..<18, using: &generator)
        while digitIndex == upperIndex { digitIndex = Int.random(in: 0..<18, using: &generator) }
        chars[upperIndex] = Character(chars[upperIndex].uppercased())
        chars[digitIndex] = digits.randomElement(using: &generator)!
        return [chars[0..<6], chars[6..<12], chars[12..<18]].map { String($0) }.joined(separator: "-")
    }
}
