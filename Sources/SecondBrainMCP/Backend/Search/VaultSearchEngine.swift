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
        var work = SearchWorkBudget()
        var ranked: [RankedResult] = []
        var moreResultsAvailable = false
        var coverageIncomplete = corpus.coverageIncomplete
        var resourceLimitedFiles = corpus.resourceLimitedFileCount
        var limitedPaths = corpus.partiallyLimitedPaths
        var searchedFiles = 0
        var skippedSensitive = corpus.skippedSensitiveFileCount

        for (index, document) in corpus.documents.enumerated() {
            try Task.checkCancellation()
            work.truncated = false
            let candidate = try bestResult(
                in: document,
                request: validated,
                work: &work
            )
            if work.truncated || work.exhausted {
                coverageIncomplete = true
                if limitedPaths.insert(document.path).inserted {
                    resourceLimitedFiles += 1
                }
            }
            // This document was evaluated even if defense-in-depth later
            // refuses one result projection derived from it.
            searchedFiles += 1

            if let candidate {
                do {
                    try validateProjection(candidate.result)
                } catch is SensitiveContentPolicy.Violation {
                    skippedSensitive += 1
                    coverageIncomplete = true
                    if work.exhausted {
                        markRemainingDocuments(
                            after: index,
                            in: corpus.documents,
                            limitedPaths: &limitedPaths,
                            resourceLimitedFiles: &resourceLimitedFiles
                        )
                        break
                    }
                    continue
                }

                if ranked.count < limits.maximumCandidates {
                    ranked.append(candidate)
                } else {
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
            }

            if work.exhausted {
                coverageIncomplete = true
                markRemainingDocuments(
                    after: index,
                    in: corpus.documents,
                    limitedPaths: &limitedPaths,
                    resourceLimitedFiles: &resourceLimitedFiles
                )
                break
            }
        }

        ranked.sort { isBetter($0, than: $1) }
        if ranked.count > validated.request.limit { moreResultsAvailable = true }
        var results: [VaultSearchResult] = []
        for candidate in ranked.prefix(validated.request.limit) {
            let tentative = VaultSearchResponse(
                strategy: validated.request.strategy,
                results: results + [candidate.result],
                searchedFileCount: searchedFiles,
                skippedFileCount: corpus.skippedFileCount,
                skippedSensitiveFileCount: skippedSensitive,
                resourceLimitedFileCount: resourceLimitedFiles,
                moreResultsAvailable: moreResultsAvailable,
                coverageIncomplete: coverageIncomplete
            )
            guard try encodedResponseByteCount(tentative)
                    <= limits.maximumResponseBytes else {
                moreResultsAvailable = true
                break
            }
            results.append(candidate.result)
        }
        let response = VaultSearchResponse(
            strategy: validated.request.strategy,
            results: results,
            searchedFileCount: searchedFiles,
            skippedFileCount: corpus.skippedFileCount,
            skippedSensitiveFileCount: skippedSensitive,
            resourceLimitedFileCount: resourceLimitedFiles,
            moreResultsAvailable: moreResultsAvailable,
            coverageIncomplete: coverageIncomplete
        )
        guard try encodedResponseByteCount(response)
            <= limits.maximumResponseBytes else {
            throw EngineError.responseLimitTooSmall
        }
        return response
    }

    private func markRemainingDocuments(
        after index: Int,
        in documents: [SearchDocument],
        limitedPaths: inout Set<String>,
        resourceLimitedFiles: inout Int
    ) {
        guard index + 1 < documents.count else { return }
        for document in documents[(index + 1)...] {
            if limitedPaths.insert(document.path).inserted {
                resourceLimitedFiles += 1
            }
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

    private func bestResult(
        in document: SearchDocument,
        request: SearchResourcePolicy.ValidatedRequest,
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
                lineEnd: 1
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
                    : (presentsSection ? section.lineStart : 1)
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
        work: inout SearchWorkBudget
    ) throws -> [FieldMatch] {
        var matches: [FieldMatch] = []
        for (field, text) in values where request.fields.contains(field) {
            guard !text.isEmpty, !work.exhausted else { continue }
            if let match = try SearchTextMatcher.match(
                text: text,
                query: request.request.query,
                queryTokens: request.queryTokens,
                strategy: request.request.strategy,
                budget: &work,
                limits: limits
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
        lineEnd: Int
    ) -> RankedResult {
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
            }
        )
        return RankedResult(result: result, score: primary + secondary)
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
