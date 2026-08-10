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
}
