import Testing
@testable import second_brain_mcp

@Suite
struct `Search fuzzy policy` {
    @Test
    func `Edit allowance is shared across short and long normalized terms`() {
        #expect(SearchFuzzyPolicy.maximumEditDistance(for: "fo") == 0)
        #expect(SearchFuzzyPolicy.maximumEditDistance(for: "focus") == 1)
        #expect(SearchFuzzyPolicy.maximumEditDistance(for: "concurrent") == 2)
    }

    @Test
    func `Bounded OSA distance handles one transposition but not two`() {
        #expect(SearchFuzzyPolicy.boundedDistance("focsu", "focus", maximum: 1) == 1)
        #expect(SearchFuzzyPolicy.boundedDistance("aba", "aab", maximum: 1) == 1)
        #expect(SearchFuzzyPolicy.boundedDistance("badc", "abcd", maximum: 1) == nil)
        #expect(SearchFuzzyPolicy.boundedDistance("badc", "abcd", maximum: 2) == 2)
    }

    @Test
    func `Cell consumer can stop the shared kernel deterministically`() {
        var cells = 0
        let distance = SearchFuzzyPolicy.boundedDistance(
            "concurent",
            "concurrent",
            maximum: 2,
            consumingCell: {
                cells += 1
                return cells <= 3
            }
        )
        #expect(distance == nil)
        #expect(cells == 4)
    }
}
