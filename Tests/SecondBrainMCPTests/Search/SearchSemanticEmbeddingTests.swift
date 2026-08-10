import Foundation
import Testing
@testable import second_brain_mcp

@Suite("Local semantic embedding")
struct SearchSemanticEmbeddingTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test("Corpus vectors are cached while transient queries are not retained")
    func boundedCacheRetention() async {
        let calls = Counter()
        let embedding = NaturalLanguageSearchSemanticEmbedding { _ in
            calls.increment()
            return [1, 0]
        }

        await withTaskGroup(of: [Double]?.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    embedding.embedding(for: "safe corpus text", retention: .reusable)
                }
            }
            for await vector in group {
                #expect(vector == [1, 0])
            }
        }
        #expect(calls.count == 1)

        _ = embedding.embedding(for: "private query", retention: .transient)
        _ = embedding.embedding(for: "private query", retention: .transient)
        #expect(calls.count == 3)

        let oversized = String(repeating: "x", count: 4 * 1_024 + 1)
        #expect(embedding.embedding(for: oversized, retention: .reusable) == nil)
        #expect(calls.count == 3)
    }

    @Test("Semantic text projection is byte bounded and Unicode safe")
    func boundedProjection() throws {
        let ascii = try SearchSemanticTextProjection.make(
            from: String(repeating: "x", count: 5 * 1_024)
        )
        #expect(ascii.utf8.count == SearchSemanticTextProjection.maximumBytes)

        let unicode = try SearchSemanticTextProjection.make(
            from: String(repeating: "x", count: 4_095) + "😀later"
        )
        #expect(unicode.utf8.count == 4_095)
        #expect(!unicode.contains("�"))
    }
}
