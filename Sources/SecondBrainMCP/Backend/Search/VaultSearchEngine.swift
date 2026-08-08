import Foundation

/// Live, bounded implementation of the shared vault-search port.
///
/// The engine has no persistent index or mutable strategy registry. It captures
/// one coordinated snapshot per note, extracts the corpus once, and selects the
/// requested behavior through one exhaustive strategy switch in
/// ``SearchTextMatcher``.
struct VaultSearchEngine: VaultSearchService, Sendable {
    enum EngineError: Error, Sendable { case responseLimitTooSmall }

    private struct RankedResult: Sendable {
        let result: VaultSearchResult
        let score: Double
    }

    private struct FieldMatch: Sendable {
        let field: SearchField
        let text: String
        let match: SearchMatch
    }

    /// Remaining relaxed-matching work, shared fairly instead of allowing one
    /// early evidence file to consume the whole request.
    private struct WorkLedger {
        var tokenComparisons: Int
        var fuzzyComparisons: Int
        var editDistanceCells: Int

        init(limits: SearchResourceLimits) {
            tokenComparisons = limits.maximumTokenComparisons
            fuzzyComparisons = limits.maximumFuzzyComparisons
            editDistanceCells = limits.maximumEditDistanceCells
        }

        func budget(remainingDocuments: Int) -> SearchWorkBudget {
            let divisor = max(remainingDocuments, 1)
            return SearchWorkBudget(
                maximumTokenComparisons: fairShare(tokenComparisons, divisor),
                maximumFuzzyComparisons: fairShare(fuzzyComparisons, divisor),
                maximumEditDistanceCells: fairShare(editDistanceCells, divisor)
            )
        }

        mutating func deduct(_ budget: SearchWorkBudget) {
            tokenComparisons = max(
                tokenComparisons - min(
                    budget.tokenComparisons,
                    budget.maximumTokenComparisons
                ),
                0
            )
            fuzzyComparisons = max(
                fuzzyComparisons - min(
                    budget.fuzzyComparisons,
                    budget.maximumFuzzyComparisons
                ),
                0
            )
            editDistanceCells = max(
                editDistanceCells - min(
                    budget.editDistanceCells,
                    budget.maximumEditDistanceCells
                ),
                0
            )
        }

        private func fairShare(_ remaining: Int, _ divisor: Int) -> Int {
            guard remaining > 0 else { return 0 }
            return max(remaining / divisor, 1)
        }
    }

    private let vaultPath: String
    private let capabilities: SearchCapabilities
    private let corpusBuilder: SearchCorpusBuilder
    private let limits: SearchResourceLimits
    private let admissionGate: AsyncExclusiveGate
    private let processSearchLock: POSIXAdvisoryFileLock?

    init(
        vaultPath: String,
        capabilities: SearchCapabilities,
        store: VaultCRUDStore,
        operations: VaultOperationCoordinator,
        limits: SearchResourceLimits = .default,
        admissionGate: AsyncExclusiveGate? = nil,
        processSearchLock: POSIXAdvisoryFileLock? = nil
    ) {
        self.vaultPath = vaultPath
        self.capabilities = capabilities
        self.limits = limits
        self.admissionGate = admissionGate ?? AsyncExclusiveGate(
            maximumWaiters: limits.maximumQueuedRequests
        )
        self.processSearchLock = processSearchLock
        self.corpusBuilder = SearchCorpusBuilder(
            vaultPath: vaultPath,
            store: store,
            operations: operations,
            limits: limits
        )
    }

    /// Searches current note snapshots and returns at most one section per file.
    func search(_ request: VaultSearchRequest) async throws -> VaultSearchResponse {
        let validated = try SearchResourcePolicy.validate(
            request,
            capabilities: capabilities,
            vaultPath: vaultPath,
            limits: limits
        )
        do {
            return try await admissionGate.withPermit {
                if let processSearchLock {
                    return try await processSearchLock.withLock(.exclusive) {
                        try await execute(validated)
                    }
                }
                return try await execute(validated)
            }
        } catch is AsyncExclusiveGate.CapacityExceeded {
            throw VaultSearchRequestError.searchBusy
        }
    }

    private func execute(
        _ validated: SearchResourcePolicy.ValidatedRequest
    ) async throws -> VaultSearchResponse {
        let corpus = try await corpusBuilder.build(for: validated)
        var ranked: [RankedResult] = []
        var moreResultsAvailable = false
        var coverageIncomplete = corpus.coverageIncomplete
        var resourceLimitedFiles = corpus.resourceLimitedFileCount
        var limitedPaths = corpus.partiallyLimitedPaths
        var resourceLimitSamples = corpus.resourceLimitSamples
        let searchedFiles = corpus.documents.count
        var skippedSensitive = corpus.skippedSensitiveFileCount
        var exactHitPaths = Set<String>()

        // Smart first performs a corpus-wide literal pass. This work is not
        // charged to fuzzy/lexical budgets, so smart can never lose an exact
        // result merely because an earlier HAR contains huge token streams.
        if validated.request.strategy == .smart {
            for document in corpus.documents {
                try Task.checkCancellation()
                var exactWork = SearchWorkBudget()
                guard let candidate = try bestResult(
                    in: document,
                    request: validated,
                    strategy: .exact,
                    allowsExact: true,
                    work: &exactWork
                ) else { continue }
                exactHitPaths.insert(document.path)
                try accept(
                    candidate,
                    minimumRelevance: validated.request.minimumRelevance,
                    ranked: &ranked,
                    moreResultsAvailable: &moreResultsAvailable,
                    skippedSensitive: &skippedSensitive,
                    coverageIncomplete: &coverageIncomplete
                )
            }
        }

        let relaxedDocuments = corpus.documents.filter {
            validated.request.strategy != .smart
                || !exactHitPaths.contains($0.path)
        }
        var ledger = WorkLedger(limits: limits)
        for (index, document) in relaxedDocuments.enumerated() {
            try Task.checkCancellation()
            var work = ledger.budget(
                remainingDocuments: relaxedDocuments.count - index
            )
            let strategy = validated.request.strategy
            let candidate = try bestResult(
                in: document,
                request: validated,
                strategy: strategy,
                allowsExact: strategy != .smart,
                work: &work
            )
            ledger.deduct(work)
            if work.truncated || work.exhausted {
                coverageIncomplete = true
                if limitedPaths.insert(document.path).inserted {
                    resourceLimitedFiles += 1
                }
                if let sample = try SearchResourceDiagnostics.sample(
                    path: document.path,
                    reason: .matching,
                    impact: .partial
                ) {
                    resourceLimitSamples = SearchResourceDiagnostics.merged(
                        resourceLimitSamples,
                        [sample]
                    )
                }
            }
            if let candidate {
                try accept(
                    candidate,
                    minimumRelevance: validated.request.minimumRelevance,
                    ranked: &ranked,
                    moreResultsAvailable: &moreResultsAvailable,
                    skippedSensitive: &skippedSensitive,
                    coverageIncomplete: &coverageIncomplete
                )
            }
        }

        ranked.sort { isBetter($0, than: $1) }
        if ranked.count > validated.request.limit { moreResultsAvailable = true }
        var results: [VaultSearchResult] = []
        let resultPayloadLimit = max((limits.maximumResponseBytes * 3) / 5, 0)
        for candidate in ranked.prefix(validated.request.limit) {
            guard try encodedResultsByteCount(results + [candidate.result])
                    <= resultPayloadLimit else {
                moreResultsAvailable = true
                break
            }
            results.append(candidate.result)
        }
        func makeResponse() -> VaultSearchResponse {
            VaultSearchResponse(
                strategy: validated.request.strategy,
                results: results,
                searchedFileCount: searchedFiles,
                skippedFileCount: corpus.skippedFileCount,
                skippedSensitiveFileCount: skippedSensitive,
                resourceLimitedFileCount: resourceLimitedFiles,
                moreResultsAvailable: moreResultsAvailable,
                coverageIncomplete: coverageIncomplete,
                minimumRelevance: validated.request.minimumRelevance,
                resourceLimitSamples: resourceLimitSamples
            )
        }
        var response = makeResponse()
        // Samples are explanatory and explicitly non-exhaustive. Preserve the
        // strategy-independent result payload before shedding diagnostics.
        while try encodedResponseByteCount(response) > limits.maximumResponseBytes,
              !resourceLimitSamples.isEmpty {
            resourceLimitSamples.removeLast()
            response = makeResponse()
        }
        guard try encodedResponseByteCount(response)
            <= limits.maximumResponseBytes else {
            throw EngineError.responseLimitTooSmall
        }
        return response
    }

    private func accept(
        _ candidate: RankedResult,
        minimumRelevance: Double,
        ranked: inout [RankedResult],
        moreResultsAvailable: inout Bool,
        skippedSensitive: inout Int,
        coverageIncomplete: inout Bool
    ) throws {
        guard candidate.result.relevance >= minimumRelevance else { return }
        do {
            try validateProjection(candidate.result)
        } catch is SensitiveContentPolicy.Violation {
            skippedSensitive += 1
            coverageIncomplete = true
            return
        }
        if ranked.count < limits.maximumCandidates {
            ranked.append(candidate)
            return
        }
        moreResultsAvailable = true
        var worst = ranked.startIndex
        for index in ranked.indices.dropFirst()
        where isBetter(ranked[worst], than: ranked[index]) {
            worst = index
        }
        if isBetter(candidate, than: ranked[worst]) {
            ranked[worst] = candidate
        }
    }

    private func encodedResponseByteCount(
        _ response: VaultSearchResponse
    ) throws -> Int {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return try encoder.encode(response).count
    }

    private func encodedResultsByteCount(
        _ results: [VaultSearchResult]
    ) throws -> Int {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(results).count
    }

    private func bestResult(
        in document: SearchDocument,
        request: SearchResourcePolicy.ValidatedRequest,
        strategy: SearchStrategy,
        allowsExact: Bool,
        work: inout SearchWorkBudget
    ) throws -> RankedResult? {
        var best: RankedResult?
        let metadataValues: [(SearchField, String)] = [
            (.title, document.title),
            (.tags, document.tags.joined(separator: " ")),
            (.path, document.path),
        ]
        let metadataMatches = try matchingFields(
            metadataValues,
            request: request,
            strategy: strategy,
            allowsExact: allowsExact,
            work: &work
        )
        if let preferred = strongestMatch(in: metadataMatches) {
            best = rankedResult(
                document: document,
                matches: metadataMatches,
                source: preferred.text,
                range: preferred.match.range,
                heading: nil,
                location: nil,
                lineStart: 1,
                lineEnd: 1,
                queryTokens: request.queryTokens
            )
        }

        for section in document.sections {
            try Task.checkCancellation()
            let localMatches = try matchingFields(
                [
                    (.heading, section.heading ?? ""),
                    (.content, section.content),
                ],
                request: request,
                strategy: strategy,
                allowsExact: allowsExact,
                work: &work
            )
            guard !localMatches.isEmpty else { continue }
            let matches = metadataMatches + localMatches
            let presentation = strongestMatch(in: matches)!
            let presentsSection = presentation.field == .heading
                || presentation.field == .content
            let candidate = rankedResult(
                document: document,
                matches: matches,
                source: presentation.text,
                range: presentation.match.range,
                heading: presentsSection ? section.heading : nil,
                location: presentation.field == .content ? section.location : nil,
                lineStart: presentsSection ? section.lineStart : 1,
                lineEnd: presentation.field == .content ? section.lineEnd
                    : (presentsSection ? section.lineStart : 1),
                queryTokens: request.queryTokens
            )
            if best == nil || isBetter(candidate, than: best!) {
                best = candidate
            }
        }
        return best
    }

    private func strongestMatch(in matches: [FieldMatch]) -> FieldMatch? {
        matches.max { lhs, rhs in
            let lhsStrength = (lhs.match.quality * 100) + fieldWeight(lhs.field)
            let rhsStrength = (rhs.match.quality * 100) + fieldWeight(rhs.field)
            if lhsStrength != rhsStrength { return lhsStrength < rhsStrength }
            return lhs.field.rawValue > rhs.field.rawValue
        }
    }

    private func matchingFields(
        _ values: [(SearchField, String)],
        request: SearchResourcePolicy.ValidatedRequest,
        strategy: SearchStrategy,
        allowsExact: Bool,
        work: inout SearchWorkBudget
    ) throws -> [FieldMatch] {
        var matches: [FieldMatch] = []
        for (field, text) in values where request.fields.contains(field) {
            guard !text.isEmpty else { continue }
            if let match = try SearchTextMatcher.match(
                text: text,
                query: request.request.query,
                queryTokens: request.queryTokens,
                strategy: strategy,
                budget: &work,
                limits: limits,
                allowsExact: allowsExact
            ) {
                matches.append(FieldMatch(field: field, text: text, match: match))
            }
        }
        return matches
    }

    private func rankedResult(
        document: SearchDocument,
        matches: [FieldMatch],
        source: String,
        range: Range<String.Index>?,
        heading: String?,
        location: VaultSearchLocation?,
        lineStart: Int,
        lineEnd: Int,
        queryTokens: [SearchToken]
    ) -> RankedResult {
        let queryTerms = Set(queryTokens.map(\.normalized))
        let coveredTerms = matches.reduce(into: Set<String>()) {
            $0.formUnion($1.match.coveredTerms)
        }
        let complete = matches.contains { $0.match.completeQuery }
        let termCoverage = complete || queryTerms.isEmpty
            ? 1
            : min(Double(coveredTerms.count) / Double(queryTerms.count), 1)
        let strongestStrength = matches.map(\.match.strength).max() ?? 0
        let strongestField = matches.map { relevanceFieldStrength($0.field) }.max() ?? 0
        let hasLiteralMatch = matches.contains { $0.match.quality == 100 }
        let relevance = hasLiteralMatch ? 1 : quantized(
            min(max(
                (0.80 * termCoverage)
                    + (0.15 * strongestStrength)
                    + (0.05 * strongestField),
                0
            ), 1)
        )
        let primary = matches.map {
            ($0.match.quality * 100) + fieldWeight($0.field)
        }.max() ?? 0
        let secondary = matches.map(\.match.quality).reduce(0, +) / 1_000
        let result = VaultSearchResult(
            path: document.path,
            format: document.format,
            title: document.title,
            heading: heading,
            location: location,
            snippet: SearchSnippetBuilder.make(
                from: source,
                around: range,
                maximumCharacters: limits.maximumSnippetCharacters,
                maximumBytes: limits.maximumSnippetBytes
            ),
            lineStart: lineStart,
            lineEnd: lineEnd,
            matchedFields: SearchField.allCases.filter { field in
                matches.contains { $0.field == field }
            },
            relevance: relevance,
            termCoverage: quantized(termCoverage),
            completeQueryFields: SearchField.allCases.filter { field in
                matches.contains { $0.field == field && $0.match.completeQuery }
            }
        )
        return RankedResult(
            result: result,
            score: (relevance * 1_000_000) + primary + secondary
        )
    }

    private func fieldWeight(_ field: SearchField) -> Double {
        switch field {
        case .title: 5
        case .heading: 4
        case .tags: 3
        case .path: 2
        case .content: 1
        }
    }

    private func relevanceFieldStrength(_ field: SearchField) -> Double {
        switch field {
        case .title: 1
        case .heading: 0.8
        case .tags: 0.6
        case .path: 0.4
        case .content: 0.2
        }
    }

    private func quantized(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }

    private func isBetter(_ lhs: RankedResult, than rhs: RankedResult) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.result.path != rhs.result.path {
            return lhs.result.path < rhs.result.path
        }
        return lhs.result.lineStart < rhs.result.lineStart
    }

    private func validateProjection(_ result: VaultSearchResult) throws {
        let fields = [
            result.path,
            result.title,
            result.heading ?? "",
            result.location?.nodeID ?? "",
            result.location?.nodeType ?? "",
            result.location?.field ?? "",
            result.snippet,
        ]
        for field in fields where !field.isEmpty {
            try SensitiveContentPolicy.validate(
                Data(field.utf8),
                format: .markdown,
                path: result.path
            )
        }
    }
}
