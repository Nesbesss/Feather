import Foundation
import NaturalLanguage
import os

/// Sentence vectors for tab notes, from NaturalLanguage's on-device contextual
/// embedding (the token vectors averaged). Its Latin-script model covers
/// English, Dutch, German, French and more. Runs on its own queue, off the main thread.
nonisolated final class TabEmbedder: @unchecked Sendable {
    static let shared = TabEmbedder()

    private let queue = DispatchQueue(label: "dev.nesbes.Feather.TabEmbedder", qos: .utility)
    private let log = Logger(subsystem: "dev.nesbes.Feather", category: "TabGroups")
    private var embedding: NLContextualEmbedding?
    private var loaded = false

    /// One vector per text, or nil when the embedding model isn't available.
    func vectors(for texts: [String]) async -> [[Double]]? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.compute(texts)) }
        }
    }

    private func compute(_ texts: [String]) -> [[Double]]? {
        guard let model = prepare() else { return nil }
        var result: [[Double]] = []
        for text in texts {
            guard let embedded = try? model.embeddingResult(for: text, language: .english) else { return nil }
            var sum = [Double](repeating: 0, count: model.dimension)
            var count = 0.0
            embedded.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                for index in vector.indices { sum[index] += vector[index] }
                count += 1
                return true
            }
            result.append(sum.map { $0 / max(count, 1) })
        }
        return result
    }

    private func prepare() -> NLContextualEmbedding? {
        if loaded { return embedding }
        guard let model = NLContextualEmbedding(language: .english) else { return nil }
        if !model.hasAvailableAssets {
            // The model downloads once, in the background; grouping falls back to topics meanwhile.
            model.requestAssets { [log] result, error in
                log.info("Embedding assets: \(result.rawValue) \(error?.localizedDescription ?? "", privacy: .public)")
            }
            return nil
        }
        do {
            try model.load()
        } catch {
            log.error("Embedding model didn't load: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        embedding = model
        loaded = true
        return model
    }
}
