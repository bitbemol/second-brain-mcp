import Testing
@testable import second_brain_mcp

@Suite
struct `Literal search matching strategy` {
    @Test
    func `Every normalized term must occur in the same atom`() {
        let matcher = LiteralSearchMatchingStrategy()
        #expect(matcher.rank(
            query: "CAFÉ actors",
            in: "Cafe patterns for ACTORS"
        ) != nil)
        #expect(matcher.rank(
            query: "actors isolation",
            in: "actors only"
        ) == nil)
    }

    @Test
    func `Exact phrase and occurrence count provide deterministic rank`() throws {
        let matcher = LiteralSearchMatchingStrategy()
        let rank = try #require(matcher.rank(
            query: "swift actors",
            in: "Swift actors; swift actors"
        ))
        #expect(rank.exactPhrase)
        #expect(rank.occurrenceCount == 4)
    }

    @Test
    func `Duplicate terms do not multiply atom scans`() throws {
        let matcher = LiteralSearchMatchingStrategy()
        let text = String(
            repeating: "alpha needle beta gamma delta ",
            count: 20_000
        )
        let duplicateQuery = Array(repeating: "needle", count: 128)
            .joined(separator: " ")

        _ = matcher.rank(query: "needle", in: "warmup needle")
        let clock = ContinuousClock()

        let singleStart = clock.now
        let singleRank = try #require(matcher.rank(query: "needle", in: text))
        let singleDuration = singleStart.duration(to: clock.now)

        let duplicateStart = clock.now
        let duplicateRank = try #require(matcher.rank(
            query: duplicateQuery,
            in: text
        ))
        let duplicateDuration = duplicateStart.duration(to: clock.now)

        // Multiplicity remains part of rank, but repeated criteria must reuse
        // the same atom scan. The relative ceiling leaves ample scheduler room.
        #expect(
            duplicateRank.occurrenceCount
                == singleRank.occurrenceCount * 128
        )
        #expect(duplicateDuration < singleDuration * 8)
    }
}
