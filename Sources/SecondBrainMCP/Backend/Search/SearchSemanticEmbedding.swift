import Foundation
import NaturalLanguage

/// Transport-neutral source of local semantic vectors for conservative search
/// fallback. Implementations return `nil` when an input cannot be represented.
enum SearchSemanticEmbeddingRetention: Equatable, Sendable {
    /// One-off caller text that must not be retained after vectorization.
    case transient
    /// Validated corpus text that may reuse a bounded in-memory vector.
    case reusable
}

protocol SearchSemanticEmbedding: Sendable {
    func embedding(
        for text: String,
        retention: SearchSemanticEmbeddingRetention
    ) -> [Double]?
}

/// Bounded access to Apple's on-device sentence embedding.
///
/// `NLEmbedding` does not declare Sendable or thread-safety guarantees, so both
/// model access and the small FIFO cache are protected by one lock.
final class NaturalLanguageSearchSemanticEmbedding: SearchSemanticEmbedding,
    @unchecked Sendable {
    static let shared = NaturalLanguageSearchSemanticEmbedding()

    private enum CacheEntry {
        case vector([Double])
        case unavailable
    }

    private static let maximumInputBytes = 4 * 1_024
    private static let maximumCacheEntries = 512

    private let vectorizer: (String) -> [Double]?
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var insertionOrder: [String] = []

    convenience init(
        model: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)
    ) {
        self.init(vectorizer: { model?.vector(for: $0) })
    }

    /// Internal seam used to verify cache behavior without depending on an OS
    /// model revision. The closure is invoked only while `lock` is held.
    init(vectorizer: @escaping (String) -> [Double]?) {
        self.vectorizer = vectorizer
    }

    func embedding(
        for text: String,
        retention: SearchSemanticEmbeddingRetention
    ) -> [Double]? {
        guard !text.isEmpty, text.utf8.count <= Self.maximumInputBytes else {
            return nil
        }
        return lock.withLock {
            if retention == .reusable, let cached = cache[text] {
                switch cached {
                case .vector(let vector): return vector
                case .unavailable: return nil
                }
            }

            let vector = vectorizer(text)
            if retention == .reusable {
                insert(vector.map(CacheEntry.vector) ?? .unavailable, for: text)
            }
            return vector
        }
    }

    private func insert(_ entry: CacheEntry, for key: String) {
        if cache[key] == nil {
            while insertionOrder.count >= Self.maximumCacheEntries,
                  let oldest = insertionOrder.first {
                insertionOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            insertionOrder.append(key)
        }
        cache[key] = entry
    }
}

/// Produces a valid UTF-8 prefix without allowing one semantic input to grow
/// with an arbitrarily large note section.
enum SearchSemanticTextProjection {
    struct Bounded: Sendable {
        let value: String
        let truncated: Bool
    }

    static let maximumBytes = 4 * 1_024

    static func make(from text: String) throws -> String {
        try bounded(from: text).value
    }

    static func bounded(from text: String) throws -> Bounded {
        guard !text.isEmpty else { return Bounded(value: "", truncated: false) }
        var byteCount = 0
        var end = text.startIndex
        var visited = 0
        while end < text.endIndex {
            if visited.isMultiple(of: 1_024) { try Task.checkCancellation() }
            visited += 1
            let next = text.index(after: end)
            let characterBytes = text[end..<next].utf8.count
            guard byteCount + characterBytes <= maximumBytes else { break }
            byteCount += characterBytes
            end = next
        }
        return Bounded(
            value: String(text[..<end]).trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            truncated: end < text.endIndex
        )
    }
}
