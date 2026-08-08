import Foundation

/// Live, bounded implementation of the shared vault-search port.
///
/// The engine has no persistent index or mutable strategy registry. It captures
/// one coordinated snapshot per file, extracts the corpus once, and selects the
/// requested behavior through one exhaustive strategy switch in
/// ``SearchTextMatcher``.
struct VaultSearchEngine: VaultSearchService, Sendable {
    enum EngineError: Error, Sendable { case responseLimitTooSmall }

    private struct RankedResult: Sendable {
        let result: VaultSearchResult
        var score: Double
        let hasWholeLiteral: Bool
        let coveredTerms: Set<String>
    }

    private struct FieldMatch: Sendable {
        let field: SearchField
        let text: String
        let match: SearchMatch
    }

    /// Deduplication key that shares result strings instead of joining a second
    /// potentially multi-kilobyte identity allocation for every candidate.
    private struct ResultIdentity: Hashable {
        let path: String
        let lineStart: Int
        let lineEnd: Int
        let nodeID: String?
        let field: String?
        let heading: String?
        let physicalPage: Int?
    }

    /// Remaining relaxed-matching work, shared fairly instead of allowing one
    /// early evidence file to consume the whole request.
    private struct WorkLedger {
        var tokenComparisons: Int
        var fuzzyComparisons: Int
        var editDistanceCells: Int
        var literalOccurrences: Int

        init(limits: SearchResourceLimits) {
            tokenComparisons = limits.maximumTokenComparisons
            fuzzyComparisons = limits.maximumFuzzyComparisons
            editDistanceCells = limits.maximumEditDistanceCells
            literalOccurrences = limits.maximumLiteralOccurrencesPerRequest
        }

        func budget(remainingDocuments: Int) -> SearchWorkBudget {
            let divisor = max(remainingDocuments, 1)
            return SearchWorkBudget(
                maximumTokenComparisons: fairShare(tokenComparisons, divisor),
                maximumFuzzyComparisons: fairShare(fuzzyComparisons, divisor),
                maximumEditDistanceCells: fairShare(editDistanceCells, divisor),
                maximumLiteralOccurrences: fairShare(literalOccurrences, divisor)
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
            literalOccurrences = max(
                literalOccurrences - min(
                    budget.literalOccurrences,
                    budget.maximumLiteralOccurrences
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
            capabilities: capabilities,
            limits: limits
        )
    }

    /// Searches current snapshots and returns bounded ranked passages.
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
        if let expected = validated.expectedCorpusFingerprint,
           expected != corpus.revisionFingerprint {
            throw VaultSearchRequestError.invalidCursor
        }
        var ranked: [RankedResult] = []
        var moreResultsAvailable = false
        var coverageIncomplete = corpus.coverageIncomplete
        var resourceLimitedFiles = corpus.resourceLimitedFileCount
        var limitedPaths = corpus.partiallyLimitedPaths
        var resourceLimitSamples = corpus.resourceLimitSamples
        let searchedFiles = corpus.documents.count
        let pdfSummary = makePDFSummary(corpus.documents)
        var skippedSensitive = corpus.skippedSensitiveFileCount
        var exactHitPaths = Set<String>()
        var acceptedIdentities = Set<ResultIdentity>()
        var acceptedHitsByPath: [String: Int] = [:]

        // Smart first performs a corpus-wide literal pass. This work is not
        // charged to fuzzy/lexical budgets, so smart can never lose an exact
        // result merely because an earlier HAR contains huge token streams.
        if validated.request.strategy == .smart {
            var exactLedger = WorkLedger(limits: limits)
            for (index, document) in corpus.documents.enumerated() {
                try Task.checkCancellation()
                var exactWork = exactLedger.budget(
                    remainingDocuments: corpus.documents.count - index
                )
                let candidates = try bestResults(
                    in: document,
                    request: validated,
                    strategy: .exact,
                    allowsExact: true,
                    work: &exactWork
                ).filter(\.hasWholeLiteral)
                exactLedger.deduct(exactWork)
                if exactWork.truncated || exactWork.exhausted {
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
                guard !candidates.isEmpty else { continue }
                exactHitPaths.insert(document.path)
                for candidate in candidates {
                    try accept(
                        candidate,
                        strategy: .smart,
                        minimumRelevance: validated.request.minimumRelevance,
                        ranked: &ranked,
                        acceptedIdentities: &acceptedIdentities,
                        acceptedHitsByPath: &acceptedHitsByPath,
                        maximumHitsPerFile: validated.request.maxHitsPerFile,
                        moreResultsAvailable: &moreResultsAvailable,
                        skippedSensitive: &skippedSensitive,
                        coverageIncomplete: &coverageIncomplete
                    )
                }
            }
        }

        let relaxedDocuments = corpus.documents.filter {
            validated.request.strategy != .smart
                || validated.request.maxHitsPerFile > 1
                || !exactHitPaths.contains($0.path)
        }
        var ledger = WorkLedger(limits: limits)
        for (index, document) in relaxedDocuments.enumerated() {
            try Task.checkCancellation()
            var work = ledger.budget(
                remainingDocuments: relaxedDocuments.count - index
            )
            let strategy = validated.request.strategy
            let candidates = try bestResults(
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
            for candidate in candidates {
                try accept(
                    candidate,
                    strategy: strategy,
                    minimumRelevance: validated.request.minimumRelevance,
                    ranked: &ranked,
                    acceptedIdentities: &acceptedIdentities,
                    acceptedHitsByPath: &acceptedHitsByPath,
                    maximumHitsPerFile: validated.request.maxHitsPerFile,
                    moreResultsAvailable: &moreResultsAvailable,
                    skippedSensitive: &skippedSensitive,
                    coverageIncomplete: &coverageIncomplete
                )
            }
        }

        applyRarityTieBreak(to: &ranked)
        ranked.sort { isBetter($0, than: $1) }
        let offset = validated.cursorOffset
        let available = offset < ranked.count
            ? Array(ranked.dropFirst(offset)) : []
        if available.count > validated.request.limit { moreResultsAvailable = true }
        var results: [VaultSearchResult] = []
        var consumedCandidates = 0
        // Reserve a conservative fixed envelope for coverage facts, PDF
        // summary, and an optional cursor before admitting result payload.
        let resultPayloadLimit = min(
            max((limits.maximumResponseBytes - 1_024) / 2, 0),
            SearchRequestLimits.maximumWireResultPayloadBytes
        )
        for candidate in available {
            guard results.count < validated.request.limit else { break }
            let individualBytes = try encodedResultsByteCount([candidate.result])
            if individualBytes > resultPayloadLimit {
                // Consume an unrepresentable candidate so its continuation
                // cursor always advances to later bounded results.
                consumedCandidates += 1
                moreResultsAvailable = true
                coverageIncomplete = true
                if limitedPaths.insert(candidate.result.path).inserted {
                    resourceLimitedFiles += 1
                }
                if let sample = try SearchResourceDiagnostics.sample(
                    path: candidate.result.path,
                    reason: .projection,
                    impact: .omitted
                ) {
                    resourceLimitSamples = SearchResourceDiagnostics.merged(
                        resourceLimitSamples,
                        [sample]
                    )
                }
                continue
            }
            guard try encodedResultsByteCount(results + [candidate.result])
                    <= resultPayloadLimit else {
                moreResultsAvailable = true
                break
            }
            results.append(candidate.result)
            consumedCandidates += 1
        }
        let consumedOffset = offset + consumedCandidates
        let knownRemaining = max(ranked.count - consumedOffset, 0)
        let omittedResultCountLowerBound = knownRemaining
            + (moreResultsAvailable && knownRemaining == 0 ? 1 : 0)
        let nextCursor = knownRemaining > 0
            ? SearchCursorCodec.encode(
                offset: consumedOffset,
                fingerprint: validated.cursorFingerprint,
                corpusFingerprint: corpus.revisionFingerprint
            ) : nil
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
                resourceLimitSamples: resourceLimitSamples,
                nextCursor: nextCursor,
                omittedResultCountLowerBound: omittedResultCountLowerBound,
                pdfSummary: pdfSummary
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
        strategy: SearchStrategy,
        minimumRelevance: Double,
        ranked: inout [RankedResult],
        acceptedIdentities: inout Set<ResultIdentity>,
        acceptedHitsByPath: inout [String: Int],
        maximumHitsPerFile: Int,
        moreResultsAvailable: inout Bool,
        skippedSensitive: inout Int,
        coverageIncomplete: inout Bool
    ) throws {
        if strategy == .fuzzy, candidate.result.termCoverage < 1 { return }
        guard candidate.result.relevance >= minimumRelevance else { return }
        guard acceptedHitsByPath[candidate.result.path, default: 0]
                < maximumHitsPerFile else { return }
        guard acceptedIdentities.insert(identity(of: candidate.result)).inserted else {
            return
        }
        do {
            try validateProjection(candidate.result)
        } catch is SensitiveContentPolicy.Violation {
            skippedSensitive += 1
            coverageIncomplete = true
            return
        }
        acceptedHitsByPath[candidate.result.path, default: 0] += 1
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

    private func identity(of result: VaultSearchResult) -> ResultIdentity {
        ResultIdentity(
            path: result.path,
            lineStart: result.lineStart,
            lineEnd: result.lineEnd,
            nodeID: result.location?.nodeID,
            field: result.location?.field,
            heading: result.heading,
            physicalPage: result.physicalPage
        )
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

    private func bestResults(
        in document: SearchDocument,
        request: SearchResourcePolicy.ValidatedRequest,
        strategy: SearchStrategy,
        allowsExact: Bool,
        work: inout SearchWorkBudget
    ) throws -> [RankedResult] {
        var candidates: [RankedResult] = []
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
            candidates.append(rankedResult(
                document: document,
                matches: metadataMatches,
                source: preferred.text,
                range: preferred.match.range,
                heading: nil,
                location: nil,
                lineStart: 1,
                lineEnd: 1,
                queryTokens: request.queryTokens,
                query: request.request.query
            ))
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
            // Metadata already has its own result. A section is independently
            // useful only when its local evidence completes the query or is
            // required to complete a distributed multi-field match.
            if metadataMatches.contains(where: \.match.completeQuery),
               !localMatches.contains(where: \.match.completeQuery) {
                continue
            }
            let matches = metadataMatches + localMatches
            guard let presentation = strongestMatch(in: localMatches) else { continue }
            let candidate = rankedResult(
                document: document,
                matches: matches,
                source: presentation.text,
                range: presentation.match.range,
                heading: section.heading,
                location: presentation.field == .content ? section.location : nil,
                lineStart: section.lineStart,
                lineEnd: presentation.field == .content ? section.lineEnd
                    : section.lineStart,
                queryTokens: request.queryTokens,
                query: request.request.query,
                physicalPage: section.physicalPage,
                printedPage: section.printedPage,
                pdfPageKind: section.pdfPageKind
            )
            candidates.append(candidate)
        }
        candidates.sort { isBetter($0, than: $1) }
        return Array(candidates.prefix(request.request.maxHitsPerFile))
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
                allowsExact: allowsExact,
                allowsPartialFuzzy: true
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
        queryTokens: [SearchToken],
        query: String,
        physicalPage: Int? = nil,
        printedPage: String? = nil,
        pdfPageKind: PDFSearchPageKind? = nil
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
        let strongestDensity = matches.map { match in
            // Density is a small tie signal, so a bounded byte-derived estimate
            // is preferable to allocating an unbounded second token projection.
            let sourceTerms = max(match.text.utf8.count / 6, 1)
            return min(
                Double(max(match.match.coveredTerms.count, 1))
                    / Double(sourceTerms),
                1
            )
        }.max() ?? 0
        let titleEqualsQuery = matches.contains {
            $0.field == .title
                && $0.match.kind == .literalWhole
                && SearchTokenizer.normalize(
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                ) == SearchTokenizer.normalize(
                    query.trimmingCharacters(in: .whitespacesAndNewlines)
                )
        }
        let unadjustedRelevance = titleEqualsQuery ? 1 : quantized(
            min(max(
                (0.72 * termCoverage)
                    + (0.18 * strongestStrength)
                    + (0.08 * strongestField)
                    + (0.02 * strongestDensity),
                0
            ), 1)
        )
        let relevance = quantized(
            unadjustedRelevance * pageRelevanceMultiplier(pdfPageKind)
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
            },
            physicalPage: physicalPage,
            printedPage: printedPage,
            pdfPageKind: pdfPageKind,
            pdfTextExtractionStatus: document.pdfTextExtractionStatus
        )
        return RankedResult(
            result: result,
            score: (relevance * 1_000_000) + primary + secondary,
            hasWholeLiteral: matches.contains { $0.match.kind == .literalWhole },
            coveredTerms: coveredTerms
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

    private func pageRelevanceMultiplier(
        _ kind: PDFSearchPageKind?
    ) -> Double {
        switch kind {
        case .tableOfContents: 0.80
        case .index: 0.84
        case .bibliography: 0.88
        case .glossary: 0.86
        case .body, nil: 1
        }
    }

    private func makePDFSummary(
        _ documents: [SearchDocument]
    ) -> VaultSearchPDFSummary {
        let statuses = documents.compactMap(\.pdfTextExtractionStatus)
        return VaultSearchPDFSummary(
            examinedFileCount: statuses.count,
            metadataOnlyFileCount: statuses.count(where: {
                $0 == .metadataOnly
            }),
            extractedFileCount: statuses.count(where: { $0 == .extracted }),
            partialFileCount: statuses.count(where: { $0 == .partial }),
            noExtractableTextFileCount: statuses.count(where: {
                $0 == .noExtractableText
            }),
            unavailableFileCount: statuses.count(where: {
                $0 == .locked || $0 == .cannotOpen
                    || $0 == .contentSkippedFileBytes
            }),
            ocrPerformed: false
        )
    }

    private func quantized(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }

    /// Adds a bounded corpus-local rarity tie-break without changing the public
    /// relevance value or making it depend on unrelated nonmatching files.
    private func applyRarityTieBreak(to ranked: inout [RankedResult]) {
        var pathsByTerm: [String: Set<String>] = [:]
        for candidate in ranked {
            for term in candidate.coveredTerms {
                pathsByTerm[term, default: []].insert(candidate.result.path)
            }
        }
        for index in ranked.indices {
            let frequencies = ranked[index].coveredTerms.compactMap {
                pathsByTerm[$0]?.count
            }
            guard !frequencies.isEmpty else { continue }
            let rarity = frequencies.map { 1 / sqrt(Double($0)) }
                .reduce(0, +) / Double(frequencies.count)
            ranked[index].score += rarity * 2_500
        }
    }

    private func isBetter(_ lhs: RankedResult, than rhs: RankedResult) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.result.path != rhs.result.path {
            return lhs.result.path < rhs.result.path
        }
        if lhs.result.physicalPage != rhs.result.physicalPage {
            return (lhs.result.physicalPage ?? 0)
                < (rhs.result.physicalPage ?? 0)
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
            result.printedPage ?? "",
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
