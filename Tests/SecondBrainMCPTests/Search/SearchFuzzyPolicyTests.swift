import Testing
@testable import second_brain_mcp

@Suite("Search fuzzy policy")
struct SearchFuzzyPolicyTests {
    @Test("Edit allowance is shared across short and long normalized terms")
    func editAllowance() {
        #expect(SearchFuzzyPolicy.maximumEditDistance(for: "fo") == 0)
        #expect(SearchFuzzyPolicy.maximumEditDistance(for: "focus") == 1)
        #expect(SearchFuzzyPolicy.maximumEditDistance(for: "concurrent") == 2)
    }

    @Test("Bounded OSA distance handles one transposition but not two")
    func transpositions() {
        #expect(SearchFuzzyPolicy.boundedDistance("focsu", "focus", maximum: 1) == 1)
        #expect(SearchFuzzyPolicy.boundedDistance("aba", "aab", maximum: 1) == 1)
        #expect(SearchFuzzyPolicy.boundedDistance("badc", "abcd", maximum: 1) == nil)
        #expect(SearchFuzzyPolicy.boundedDistance("badc", "abcd", maximum: 2) == 2)
    }

    @Test("Cell consumer can stop the shared kernel deterministically")
    func workBudget() {
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
