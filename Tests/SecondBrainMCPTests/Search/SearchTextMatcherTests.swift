import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Vault search matching` {
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

    @Test
    func `Exact matching preserves punctuation and treats regex syntax literally`() throws {
        #expect(try match("stale .git/index.lock detected", query: ".git/index.lock", strategy: .exact) != nil)
        #expect(try match("ordinary text", query: ".*", strategy: .exact) == nil)
        #expect(try match("contains .* literally", query: ".*", strategy: .exact) != nil)
        #expect(try match("(a+)+$", query: "(a+)+$", strategy: .exact) != nil)
    }

    @Test
    func `Phrase requires adjacent ordered tokens across punctuation`() throws {
        #expect(try match("Swift, structured concurrency", query: "structured concurrency", strategy: .phrase) != nil)
        #expect(try match("concurrency is structured", query: "structured concurrency", strategy: .phrase) == nil)
        #expect(try match("structured and safe concurrency", query: "structured concurrency", strategy: .phrase) == nil)
    }

    @Test
    func `Lexical search accepts partial coverage without duplicate amplification`() throws {
        let once = try #require(try match("actors coordinate writes", query: "actors actors missing", strategy: .lexical))
        let duplicate = try #require(try match("actors coordinate writes", query: "actors missing", strategy: .lexical))
        #expect(once.quality == duplicate.quality)
    }

    @Test
    func `Lexical evidence records whether terms form one cohesive passage`() throws {
        let adjacent = try #require(try match(
            "binary search implementation",
            query: "binary search",
            strategy: .lexical
        ))
        let scattered = try #require(try match(
            "binary attachments belong to a different sentence with unrelated words before search canvas",
            query: "binary search",
            strategy: .lexical
        ))

        #expect(adjacent.cohesion == 1)
        #expect(scattered.cohesion < adjacent.cohesion)

        let repeatedSource = "binary unrelated archive prose search then binary search"
        let repeated = try #require(try match(
            repeatedSource,
            query: "binary search",
            strategy: .lexical
        ))
        #expect(repeated.cohesion == 1)
        #expect(repeated.range.map { String(repeatedSource[$0]) } == "binary search")
    }

    @Test
    func `Word strategies never promote embedded substrings`() throws {
        for strategy in [SearchStrategy.lexical, .phrase, .fuzzy, .smart] {
            #expect(try match("notifications applications aguacate", query: "cat", strategy: strategy) == nil)
            #expect(try match("refactoring factorial interactor", query: "actor", strategy: strategy) == nil)
            #expect(try match("research notes", query: "search", strategy: strategy) == nil)
        }
        let embedded = try #require(try match(
            "research notes",
            query: "search",
            strategy: .exact
        ))
        #expect(embedded.kind == .literalSubstring)
        #expect(embedded.quality < 100)
        let whole = try #require(try match(
            "research then search notes",
            query: "search",
            strategy: .exact
        ))
        #expect(whole.kind == .literalWhole)
    }

    @Test
    func `Conversational punctuation does not force literal-only matching`() throws {
        let text = "App leftovers are stored in the user Library folder."
        for query in [
            "where should I look for files left after uninstalling an app?",
            "where should I look for files left after uninstalling an app,",
            "where should I look for files left after uninstalling an app:",
        ] {
            let tokens = SearchQueryAnalyzer.significantTokens(in: query)
            var budget = SearchWorkBudget()
            #expect(try SearchTextMatcher.match(
                text: text,
                query: query,
                queryTokens: tokens,
                strategy: .smart,
                budget: &budget,
                limits: .default,
                allowsPartialFuzzy: true
            ) != nil)
        }
    }

    @Test
    func `Dense embedded literal occurrences stop at a declared ceiling`() throws {
        let source = String(repeating: "cat", count: 2_000) + " cat"
        let limits = searchTestLimits(maximumLiteralOccurrencesPerField: 32)
        var budget = SearchWorkBudget()
        let result = try SearchTextMatcher.match(
            text: source,
            query: "cat",
            queryTokens: SearchTokenizer.tokens(in: "cat"),
            strategy: .exact,
            budget: &budget,
            limits: limits
        )
        #expect(result?.kind == .literalSubstring)
        #expect(budget.truncated)
    }

    @Test
    func `Identifier tokenization understands camel and acronym boundaries`() throws {
        #expect(try match("SwiftUI state", query: "swift ui", strategy: .phrase) != nil)
        #expect(try match("URLSession task", query: "url session", strategy: .phrase) != nil)
        #expect(try match("MainActor", query: "actor", strategy: .lexical) != nil)
        #expect(try match("@MainActor", query: "@main", strategy: .smart) == nil)
        #expect(try match("@main entry", query: "@main", strategy: .smart) != nil)
    }

    @Test
    func `Fuzzy search repairs realistic typos but not short words`() throws {
        #expect(try match("concurrent git lock", query: "concurent git lok", strategy: .fuzzy) != nil)
        #expect(try match("an unrelated catalog", query: "concurent git lok", strategy: .fuzzy) == nil)
        #expect(try match("go runtime", query: "fo", strategy: .fuzzy) == nil)
    }

    @Test
    func `Fuzzy search repairs one adjacent transposition`() throws {
        #expect(try match("focus", query: "focsu", strategy: .fuzzy) != nil)
        #expect(try match(
            "swimlane focus",
            query: "swimlane focsu",
            strategy: .fuzzy
        ) != nil)
        #expect(try match("aab", query: "aba", strategy: .fuzzy) != nil)

        // Four-character terms receive one edit. These two independent swaps
        // therefore remain outside the conservative typo boundary.
        #expect(try match("abcd", query: "badc", strategy: .fuzzy) == nil)
    }

    @Test
    func `Fuzzy assignment finds a valid distinct-token mapping`() throws {
        // A greedy exact-first matcher consumes `abc` for the first term and
        // then cannot place `abd`. The valid mapping is abc -> axc and
        // abd -> abc, with each source position used exactly once.
        #expect(try match("abc axc", query: "abc abd", strategy: .fuzzy) != nil)
        #expect(try match("axc ayb", query: "abc ayc", strategy: .fuzzy) != nil)
    }

    @Test
    func `Fuzzy quality uses the best assignment independent of token order`() throws {
        let forward = try #require(try match(
            "abc axc",
            query: "abc ayc",
            strategy: .fuzzy
        ))
        let reversed = try #require(try match(
            "axc abc",
            query: "abc ayc",
            strategy: .fuzzy
        ))
        #expect(forward.quality == reversed.quality)
        #expect(forward.quality == 56)
    }

    @Test
    func `Closer fuzzy matches receive a higher quality score`() throws {
        let oneEdit = try #require(try match(
            "abcdefgi",
            query: "abcdefgh",
            strategy: .fuzzy
        ))
        let twoEdits = try #require(try match(
            "abcdxfgi",
            query: "abcdefgh",
            strategy: .fuzzy
        ))
        #expect(oneEdit.quality > twoEdits.quality)
    }

    @Test
    func `Unicode normalization never reuses folded indices`() throws {
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

        let multiline = "prefix\n\n\n\nNEEDLE suffix"
        let needle = try #require(multiline.range(of: "NEEDLE"))
        let bounded = SearchSnippetBuilder.make(
            from: multiline,
            around: needle,
            maximumCharacters: 12,
            maximumBytes: 64
        )
        #expect(bounded.count <= 12)
        #expect(bounded.contains("NEEDLE"))

        let separated = SearchSnippetBuilder.make(
            from: "sk_\u{0000}live_abcdefghijklmnopqrstuvwx",
            around: nil,
            maximumCharacters: 80,
            maximumBytes: 256
        )
        #expect(!separated.contains("sk_live_"))
        #expect(separated.contains("sk_ live_"))
    }

    @Test
    func `Fuzzy work stops at deterministic operation budgets`() throws {
        let tiny = SearchResourceLimits(
            maximumQueryBytes: 1_024,
            maximumQueryTokens: 64,
            maximumTokenScalars: 64,
            maximumResults: 50,
            maximumDirectoryEntries: 100,
            maximumFiles: 100,
            maximumFileBytes: 1_024,
            maximumAggregateBytes: 1_024,
            maximumAggregateProjectionBytes: 1_024,
            maximumAggregateSections: 100,
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
            maximumLiteralOccurrencesPerField: 100,
            maximumLiteralOccurrencesPerRequest: 1_000,
            maximumTokenComparisons: 100,
            maximumFuzzyComparisons: 2,
            maximumEditDistanceCells: 20,
            maximumQueuedRequests: 1,
            maximumStructuredValuesPerFile: 100,
            maximumPDFPagesPerFile: 10,
            maximumPDFTextBytesPerFile: 1_024
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

    @Test
    func `Word strategies split snake-case identifiers`() throws {
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

    @Test
    func `Distinct fuzzy terms cannot reuse one source token`() throws {
        #expect(try match("git", query: "git bit", strategy: .fuzzy) == nil)
    }

    @Test
    func `Source token and general comparison work are independently bounded`() throws {
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

    @Test
    func `Dense fuzzy assignment consumes the shared work budget`() throws {
        var budget = SearchWorkBudget()
        let bounded = searchTestLimits(
            maximumSourceTokensPerField: 100,
            maximumTokenComparisons: 16
        )
        let query = "abb aba aab aaa"
        let result = try SearchTextMatcher.match(
            text: "aaa aab aba abb",
            query: query,
            queryTokens: SearchTokenizer.tokens(in: query),
            strategy: .fuzzy,
            budget: &budget,
            limits: bounded
        )
        #expect(result == nil)
        #expect(budget.exhausted)
    }

    @Test
    func `Explicit fuzzy requires every term while smart can fall back`() throws {
        #expect(try match(
            "swimlane unrelated",
            query: "swimlane focsu",
            strategy: .fuzzy
        ) == nil)
        #expect(try match(
            "swimlane unrelated",
            query: "swimlane focsu",
            strategy: .smart
        ) != nil)
    }
}
