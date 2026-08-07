import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Vault search matching")
struct SearchTextMatcherTests {
    private let limits = SearchResourceLimits.default

    private func match(
        _ text: String,
        query: String,
        strategy: SearchStrategy
    ) throws -> SearchMatch? {
        var budget = SearchWorkBudget()
        return try SearchTextMatcher.match(
            text: text,
            query: query,
            queryTokens: SearchTokenizer.tokens(in: query),
            strategy: strategy,
            budget: &budget,
            limits: limits
        )
    }

    @Test("Exact matching preserves punctuation and treats regex syntax literally")
    func exactIdentifiers() throws {
        #expect(try match("stale .git/index.lock detected", query: ".git/index.lock", strategy: .exact) != nil)
        #expect(try match("ordinary text", query: ".*", strategy: .exact) == nil)
        #expect(try match("contains .* literally", query: ".*", strategy: .exact) != nil)
        #expect(try match("(a+)+$", query: "(a+)+$", strategy: .exact) != nil)
    }

    @Test("Phrase requires adjacent ordered tokens across punctuation")
    func phrase() throws {
        #expect(try match("Swift, structured concurrency", query: "structured concurrency", strategy: .phrase) != nil)
        #expect(try match("concurrency is structured", query: "structured concurrency", strategy: .phrase) == nil)
        #expect(try match("structured and safe concurrency", query: "structured concurrency", strategy: .phrase) == nil)
    }

    @Test("Lexical search accepts partial coverage without duplicate amplification")
    func lexical() throws {
        let once = try #require(try match("actors coordinate writes", query: "actors actors missing", strategy: .lexical))
        let duplicate = try #require(try match("actors coordinate writes", query: "actors missing", strategy: .lexical))
        #expect(once.quality == duplicate.quality)
    }

    @Test("Fuzzy search repairs realistic typos but not short words")
    func fuzzy() throws {
        #expect(try match("concurrent git lock", query: "concurent git lok", strategy: .fuzzy) != nil)
        #expect(try match("an unrelated catalog", query: "concurent git lok", strategy: .fuzzy) == nil)
        #expect(try match("go runtime", query: "fo", strategy: .fuzzy) == nil)
    }

    @Test("Unicode normalization never reuses folded indices")
    func unicodeRangesAndSnippets() throws {
        let source = "🧠 notes about İSTANBUL and cafe\u{301} design"
        let found = try #require(try match(source, query: "istanbul", strategy: .exact))
        let snippet = SearchSnippetBuilder.make(
            from: source,
            around: found.range,
            maximumCharacters: 80,
            maximumBytes: 256
        )
        #expect(snippet.contains("İSTANBUL"))
        #expect(try match(source, query: "café", strategy: .exact) != nil)
    }

    @Test("Fuzzy work stops at deterministic operation budgets")
    func fuzzyBudget() throws {
        let tiny = SearchResourceLimits(
            maximumQueryBytes: 1_024,
            maximumQueryTokens: 64,
            maximumTokenScalars: 64,
            maximumResults: 50,
            maximumDirectoryEntries: 100,
            maximumFiles: 100,
            maximumAggregateBytes: 1_024,
            maximumSectionsPerFile: 10,
            maximumMarkdownLines: 100,
            maximumFrontMatterLines: 20,
            maximumTags: 10,
            maximumAggregateTagBytes: 256,
            maximumCandidates: 10,
            maximumMetadataCharacters: 100,
            maximumMetadataBytes: 256,
            maximumSnippetCharacters: 100,
            maximumSnippetBytes: 256,
            maximumResponseBytes: 1_024,
            maximumSourceTokensPerField: 100,
            maximumTokenComparisons: 100,
            maximumFuzzyComparisons: 2,
            maximumEditDistanceCells: 20
        )
        var budget = SearchWorkBudget()
        _ = try SearchTextMatcher.match(
            text: "alpha bravo charlie delta echo foxtrot",
            query: "zzzzzzzz",
            queryTokens: SearchTokenizer.tokens(in: "zzzzzzzz"),
            strategy: .fuzzy,
            budget: &budget,
            limits: tiny
        )
        #expect(budget.exhausted)
    }

    @Test("Word strategies split snake-case identifiers")
    func snakeCaseRecall() throws {
        #expect(try match(
            "the git_index_lock is stale",
            query: "git index lock",
            strategy: .phrase
        ) != nil)
        #expect(try match(
            "the git_index_lock is stale",
            query: "index lock",
            strategy: .lexical
        ) != nil)
    }

    @Test("Distinct fuzzy terms cannot reuse one source token")
    func distinctFuzzyAssignment() throws {
        #expect(try match("git", query: "git bit", strategy: .fuzzy) == nil)
    }

    @Test("Source token and general comparison work are independently bounded")
    func generalWorkBounds() throws {
        var tokenBudget = SearchWorkBudget()
        let tokenLimits = searchTestLimits(
            maximumSourceTokensPerField: 3,
            maximumTokenComparisons: 100
        )
        let late = try SearchTextMatcher.match(
            text: "one two three four target",
            query: "target absent",
            queryTokens: SearchTokenizer.tokens(in: "target absent"),
            strategy: .lexical,
            budget: &tokenBudget,
            limits: tokenLimits
        )
        #expect(late == nil)
        #expect(tokenBudget.truncated)

        var comparisonBudget = SearchWorkBudget()
        let comparisonLimits = searchTestLimits(
            maximumSourceTokensPerField: 100,
            maximumTokenComparisons: 2
        )
        _ = try SearchTextMatcher.match(
            text: "one two three four five",
            query: "absent",
            queryTokens: SearchTokenizer.tokens(in: "absent"),
            strategy: .lexical,
            budget: &comparisonBudget,
            limits: comparisonLimits
        )
        #expect(comparisonBudget.exhausted)
    }
}
