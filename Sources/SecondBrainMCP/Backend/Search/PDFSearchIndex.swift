import Foundation

/// Search-ready metadata and candidate pages for one current indexed PDF.
struct PDFIndexedSearchDocument: Sendable {
    let document: SearchDocument
    let revisionState: String
    let candidateLimited: Bool
    let titleTruncated: Bool
}

/// Scoped index response plus explicit unavailable and policy-limited paths.
struct PDFIndexedSearchBatch: Sendable {
    let documentsByPath: [String: PDFIndexedSearchDocument]
    let candidateLimited: Bool
    let unavailablePaths: Set<String>
    let sensitivePaths: Set<String>
    let fileByteLimitedPaths: Set<String>
}

/// Persistent incremental PDF text index. The actor owns SQLite access while
/// advisory locks prevent independent MCP processes from extracting the same
/// stale document concurrently.
actor PDFSearchIndex {
    /// Independent resource policy for persistent ingestion and query hydration.
    ///
    /// Production ingestion deliberately accepts every PDF supported by the
    /// vault's 512 MiB file policy so large books remain searchable. A query
    /// never loads that source wholesale from the index: candidate pages and
    /// extracted text are hydrated under separate per-query ceilings, then the
    /// live search corpus applies its own aggregate projection budget.
    struct Configuration: Equatable, Sendable {
        /// Maximum candidate pages materialized from SQLite for one search.
        let maximumHydratedPagesPerQuery: Int
        /// Maximum candidate page-text bytes materialized for one search.
        let maximumHydratedTextBytesPerQuery: Int
        /// Maximum SQLite progress callbacks spent selecting candidate pages.
        let maximumCandidateQueryWorkCallbacks: Int
        /// Maximum private derived-index storage before new extraction pauses.
        let maximumDatabaseBytes: Int64
        /// Maximum source PDF bytes admitted to persistent extraction.
        let maximumIndexedSourceFileBytes: Int
        /// Complete versioned projection policy for rows written to SQLite.
        let extraction: PDFIndexExtractor.Configuration
        /// Maximum SQLite progress callbacks spent expanding fuzzy vocabulary.
        let maximumFuzzyVocabularyWorkCallbacks: Int

        init(
            maximumHydratedPagesPerQuery: Int = 10_000,
            maximumHydratedTextBytesPerQuery: Int = 64 * 1_024 * 1_024,
            maximumCandidateQueryWorkCallbacks: Int = 25_000,
            maximumDatabaseBytes: Int64 = 4 * 1_024 * 1_024 * 1_024,
            maximumIndexedSourceFileBytes: Int = FileFormat.pdf.maximumFileBytes,
            extraction: PDFIndexExtractor.Configuration = .production,
            maximumFuzzyVocabularyWorkCallbacks: Int = 10_000
        ) {
            self.maximumHydratedPagesPerQuery = maximumHydratedPagesPerQuery
            self.maximumHydratedTextBytesPerQuery =
                maximumHydratedTextBytesPerQuery
            self.maximumCandidateQueryWorkCallbacks =
                maximumCandidateQueryWorkCallbacks
            self.maximumDatabaseBytes = maximumDatabaseBytes
            self.maximumIndexedSourceFileBytes = maximumIndexedSourceFileBytes
            self.extraction = extraction
            self.maximumFuzzyVocabularyWorkCallbacks =
                maximumFuzzyVocabularyWorkCallbacks
        }

        /// Production policy: full supported PDF ingestion with bounded queries.
        static let production = Configuration()
    }

    private struct IndexChangedDuringRequest: Error {}

    private struct FuzzyExpansion: Sendable {
        let terms: [String]
        let limited: Bool
    }

    private struct FTSExpression: Sendable {
        let value: String
        let limited: Bool
    }

    private struct CandidateHydration: Sendable {
        let recordsByPath: [String: PDFIndexDocumentRecord]
        let pagesByDocument: [Int64: [PDFIndexCandidatePage]]
        let limited: Bool
    }

    private let databaseURL: URL
    private let vaultRoot: URL
    private let admission: PDFReadAdmission
    private let writerLock: POSIXAdvisoryFileLock?
    private let configuration: Configuration
    private let extractionObserver: (@Sendable () -> Void)?
    private let candidateQueryObserver: (@Sendable () -> Void)?
    private var databaseStorage: PDFSearchIndexDatabase?
    private var fuzzyTermCache: [String: FuzzyExpansion] = [:]
    private var fuzzyCacheGeneration: Int?
    private var observedDatabaseGeneration: Int?
    private var storageFullGeneration: Int?

    init(
        databaseURL: URL,
        vaultPath: String,
        admission: PDFReadAdmission,
        writerLock: POSIXAdvisoryFileLock? = nil,
        configuration: Configuration,
        extractionObserver: (@Sendable () -> Void)? = nil,
        candidateQueryObserver: (@Sendable () -> Void)? = nil
    ) {
        self.databaseURL = databaseURL
        self.vaultRoot = URL(fileURLWithPath: vaultPath)
        self.admission = admission
        self.writerLock = writerLock
        self.configuration = configuration
        self.extractionObserver = extractionObserver
        self.candidateQueryObserver = candidateQueryObserver
    }

    /// Opens and hardens the index without extracting vault content.
    func prepare() async throws {
        let preparation: @Sendable () async throws -> Void = {
            try await self.prepareAfterWriterLock()
        }
        if let writerLock {
            try await writerLock.withLock(.exclusive, operation: preparation)
        } else {
            try await preparation()
        }
    }

    /// Opens under the cross-process writer permit, replacing only a
    /// still-corrupt, fully validated derived bundle.
    private func prepareAfterWriterLock() throws {
        do {
            _ = try database()
        } catch let current as PDFSearchIndexDatabase.DatabaseError
            where current.permitsDerivedIndexRebuild {
            databaseStorage = nil
            fuzzyTermCache.removeAll(keepingCapacity: true)
            fuzzyCacheGeneration = nil
            storageFullGeneration = nil
            observedDatabaseGeneration = nil
            try PDFSearchIndexDatabase.discardBundleForRebuild(at: databaseURL)
            _ = try database()
        }
    }

    func indexedDocument(
        target: ReadableFileTarget,
        request: SearchResourcePolicy.ValidatedRequest
    ) async throws -> PDFIndexedSearchDocument {
        let batch = try await indexedDocuments(
            targets: [target],
            request: request
        )
        guard let result = batch.documentsByPath[target.relativePath] else {
            throw PDFSearchIndexDatabase.DatabaseError(
                operation: "lookup",
                message: "missing current record"
            )
        }
        return result
    }

    /// Refreshes stale documents individually, then performs at most one exact
    /// and one FTS candidate query for the complete current scope.
    func indexedDocuments(
        targets: [ReadableFileTarget],
        request: SearchResourcePolicy.ValidatedRequest,
        authoritativeScopePrefix: String? = nil
    ) async throws -> PDFIndexedSearchBatch {
        do {
            return try await indexedDocumentsOnce(
                targets: targets,
                request: request,
                authoritativeScopePrefix: authoritativeScopePrefix
            )
        } catch is IndexChangedDuringRequest {
            return try await indexedDocumentsOnce(
                targets: targets,
                request: request,
                authoritativeScopePrefix: authoritativeScopePrefix
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PDFSearchIndexDatabase.DatabaseError
            where failure.permitsDerivedIndexRebuild {
            databaseStorage = nil
            fuzzyTermCache.removeAll(keepingCapacity: true)
            fuzzyCacheGeneration = nil
            storageFullGeneration = nil
            observedDatabaseGeneration = nil
            try await prepare()
            return try await indexedDocumentsOnce(
                targets: targets,
                request: request,
                authoritativeScopePrefix: authoritativeScopePrefix
            )
        }
    }

    private func indexedDocumentsOnce(
        targets: [ReadableFileTarget],
        request: SearchResourcePolicy.ValidatedRequest,
        authoritativeScopePrefix: String?
    ) async throws -> PDFIndexedSearchBatch {
        let needsContent = request.fields.contains(.content)
        var recordsByPath: [String: PDFIndexDocumentRecord] = [:]
        var unavailablePaths = Set<String>()
        var sensitivePaths = Set<String>()
        var fileByteLimitedPaths = Set<String>()
        let existingRecords = try await recordsUnderRecoveryLock(
            paths: targets.map(\.relativePath)
        )
        for target in targets {
            try Task.checkCancellation()
            do {
                recordsByPath[target.relativePath] = try await currentRecord(
                    target: target,
                    needsContent: needsContent,
                    existing: existingRecords[target.relativePath]
                )
            } catch is SensitiveContentPolicy.Violation {
                sensitivePaths.insert(target.relativePath)
            } catch is FileResourcePolicy.Violation {
                fileByteLimitedPaths.insert(target.relativePath)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as PDFSearchIndexDatabase.DatabaseError
                where failure.permitsDerivedIndexRebuild {
                throw failure
            } catch {
                unavailablePaths.insert(target.relativePath)
            }
        }
        if let authoritativeScopePrefix {
            try await pruneMissingUnderWriterLock(
                scopePrefix: authoritativeScopePrefix,
                currentPaths: targets.map(\.relativePath)
            )
        }
        let hydration = try await candidatesUnderRecoveryLock(
            paths: Array(recordsByPath.keys),
            needsContent: needsContent,
            request: request
        )
        recordsByPath = hydration.recordsByPath
        let pagesByDocument = hydration.pagesByDocument
        let candidateLimited = hydration.limited
        let searchableRecordCount = recordsByPath.values.count {
            needsContent && ($0.status == .extracted || $0.status == .partial)
        }
        var results: [String: PDFIndexedSearchDocument] = [:]
        for record in recordsByPath.values {
            let sections = pagesByDocument[record.id, default: []].map { page in
                SearchSection(
                    heading: nil,
                    location: nil,
                    content: page.rawText,
                    lineStart: 1,
                    lineEnd: page.lineCount,
                    physicalPage: page.physicalPage,
                    printedPage: page.printedPage,
                    pdfPageKind: page.kind
                )
            }
            let recordCandidateLimited = candidateLimited && searchableRecordCount == 1
            results[record.path] = indexedResult(
                record: record,
                sections: sections,
                needsContent: needsContent,
                candidateLimited: recordCandidateLimited
            )
        }
        return PDFIndexedSearchBatch(
            documentsByPath: results,
            candidateLimited: candidateLimited,
            unavailablePaths: unavailablePaths,
            sensitivePaths: sensitivePaths,
            fileByteLimitedPaths: fileByteLimitedPaths
        )
    }

    private func pruneMissingUnderWriterLock(
        scopePrefix: String,
        currentPaths: [String]
    ) async throws {
        let operation: @Sendable () async throws -> Void = {
            try await self.pruneMissing(
                scopePrefix: scopePrefix,
                currentPaths: currentPaths
            )
        }
        if let writerLock {
            try await writerLock.withLock(.exclusive, operation: operation)
        } else {
            try await operation()
        }
    }

    private func pruneMissing(
        scopePrefix: String,
        currentPaths: [String]
    ) throws {
        if try database().pruneMissing(
            scopePrefix: scopePrefix,
            currentPaths: currentPaths
        ) > 0 {
            fuzzyTermCache.removeAll(keepingCapacity: true)
            fuzzyCacheGeneration = nil
            storageFullGeneration = nil
        }
    }

    private func recordsUnderRecoveryLock(
        paths: [String]
    ) async throws -> [String: PDFIndexDocumentRecord] {
        let operation: @Sendable () async throws -> [String: PDFIndexDocumentRecord] = {
            try await self.records(paths: paths)
        }
        if let writerLock {
            return try await writerLock.withLock(.shared, operation: operation)
        }
        return try await operation()
    }

    private func records(
        paths: [String]
    ) throws -> [String: PDFIndexDocumentRecord] {
        let db = try database()
        let generation = try db.generation()
        if observedDatabaseGeneration != generation {
            storageFullGeneration = nil
            observedDatabaseGeneration = generation
        }
        return try db.records(paths: paths)
    }

    private func candidatesUnderRecoveryLock(
        paths: [String],
        needsContent: Bool,
        request: SearchResourcePolicy.ValidatedRequest
    ) async throws -> CandidateHydration {
        let operation: @Sendable () async throws -> CandidateHydration = {
            try await self.hydrateCandidates(
                paths: paths,
                needsContent: needsContent,
                request: request
            )
        }
        if let writerLock {
            return try await writerLock.withLock(.shared, operation: operation)
        }
        return try await operation()
    }

    private func hydrateCandidates(
        paths: [String],
        needsContent: Bool,
        request: SearchResourcePolicy.ValidatedRequest
    ) throws -> CandidateHydration {
        let currentRecords = try database().records(paths: paths)
        guard currentRecords.count == Set(paths).count else {
            throw IndexChangedDuringRequest()
        }
        let records = Array(currentRecords.values)
        let searchable = records.filter {
            needsContent && ($0.status == .extracted || $0.status == .partial)
        }
        var pagesByDocument: [Int64: [PDFIndexCandidatePage]] = [:]
        var candidateLimited = false
        var hydratedPageCount = 0
        var hydratedTextBytes = 0
        func merge(_ value: PDFIndexCandidateBatch) {
            candidateLimited = candidateLimited || value.limited
            hydratedPageCount += value.pageCount
            hydratedTextBytes += value.textBytes
            for (documentID, pages) in value.pagesByDocument {
                var current = Dictionary(uniqueKeysWithValues:
                    pagesByDocument[documentID, default: []].map {
                        ($0.physicalPage, $0)
                    }
                )
                for page in pages { current[page.physicalPage] = page }
                pagesByDocument[documentID] = current.values.sorted {
                    $0.physicalPage < $1.physicalPage
                }
            }
        }

        let documentIDs = searchable.map(\.id)
        let db = try database()
        let needsLiteralFallback = request.request.strategy == .exact
            || (request.request.strategy == .smart && request.queryTokens.isEmpty)
        if !documentIDs.isEmpty, needsLiteralFallback {
            let folded = request.request.query.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            candidateQueryObserver?()
            let remainingPages = max(
                configuration.maximumHydratedPagesPerQuery - hydratedPageCount,
                0
            )
            let remainingBytes = max(
                configuration.maximumHydratedTextBytesPerQuery - hydratedTextBytes,
                0
            )
            if remainingPages > 0, remainingBytes > 0 {
                merge(try db.scopedExactPages(
                    documentIDs: documentIDs,
                    foldedQuery: folded,
                    maximum: remainingPages,
                    maximumTextBytes: remainingBytes,
                    maximumWorkCallbacks: configuration
                        .maximumCandidateQueryWorkCallbacks
                ))
            } else {
                candidateLimited = true
            }
        }
        if !documentIDs.isEmpty, request.request.strategy != .exact {
            let queryTerms = request.queryTokens.map(\.normalized)
            let uniqueQueryTerms = orderedUnique(queryTerms)
            var expandedTerms = uniqueQueryTerms
            if request.request.strategy == .fuzzy || request.request.strategy == .smart {
                let expansion = try fuzzyTerms(for: request.queryTokens, database: db)
                expandedTerms.append(contentsOf: expansion.terms)
                candidateLimited = candidateLimited || expansion.limited
            }
            let expressionTerms = request.request.strategy == .phrase
                ? queryTerms : orderedUnique(expandedTerms)
            if let expression = ftsExpression(
                terms: expressionTerms,
                phrase: request.request.strategy == .phrase
            ) {
                candidateLimited = candidateLimited || expression.limited
                candidateQueryObserver?()
                let remainingPages = max(
                    configuration.maximumHydratedPagesPerQuery - hydratedPageCount,
                    0
                )
                let remainingBytes = max(
                    configuration.maximumHydratedTextBytesPerQuery - hydratedTextBytes,
                    0
                )
                if remainingPages > 0, remainingBytes > 0 {
                    merge(try db.scopedFTSPages(
                        documentIDs: documentIDs,
                        expression: expression.value,
                        maximum: remainingPages,
                        maximumTextBytes: remainingBytes,
                        maximumWorkCallbacks: configuration
                            .maximumCandidateQueryWorkCallbacks
                    ))
                } else {
                    candidateLimited = true
                }
            }
        }
        return CandidateHydration(
            recordsByPath: currentRecords,
            pagesByDocument: pagesByDocument,
            limited: candidateLimited
        )
    }

    private func currentRecord(
        target: ReadableFileTarget,
        needsContent: Bool,
        existing: PDFIndexDocumentRecord?
    ) async throws -> PDFIndexDocumentRecord {
        var metadata = try VaultFileInspector.stableMetadata(target, vaultRoot: vaultRoot)
        guard metadata.byteCount <= configuration.maximumIndexedSourceFileBytes else {
            throw FileResourcePolicy.Violation(
                path: target.relativePath,
                bytes: metadata.byteCount,
                limit: configuration.maximumIndexedSourceFileBytes
            )
        }
        var quick = PDFIndexQuickIdentity(metadata: metadata)
        var record = existing
        if let record, isUsable(record, quick: quick, needsContent: needsContent) {
            return record
        }
        if storageFullGeneration == observedDatabaseGeneration {
            throw PDFSearchIndexDatabase.DatabaseError(
                operation: "publish",
                message: "derived index storage ceiling remains exhausted"
            )
        }
        if !isUsable(record, quick: quick, needsContent: needsContent) {
            do {
                record = try await refresh(
                    target: target,
                    quick: quick,
                    includePages: needsContent
                )
            } catch let failure as PDFSearchIndexDatabase.DatabaseError
                where failure.isStorageFull {
                storageFullGeneration = observedDatabaseGeneration
                throw failure
            }
            metadata = try VaultFileInspector.stableMetadata(target, vaultRoot: vaultRoot)
            quick = PDFIndexQuickIdentity(metadata: metadata)
        }
        guard let record, record.quickIdentity == quick else {
            throw BoundedFileReader.ReadError.changedDuringRead
        }
        return record
    }

    private func indexedResult(
        record: PDFIndexDocumentRecord,
        sections: [SearchSection],
        needsContent: Bool,
        candidateLimited: Bool
    ) -> PDFIndexedSearchDocument {
        let projectedStatus: PDFTextExtractionStatus
        if needsContent, candidateLimited, record.status == .extracted {
            projectedStatus = .partial
        } else if needsContent || record.status == .cannotOpen {
            projectedStatus = record.status
        } else {
            projectedStatus = .metadataOnly
        }
        return PDFIndexedSearchDocument(
            document: SearchDocument(
                path: record.path,
                format: .pdf,
                title: record.title,
                tags: [],
                sections: sections,
                pdfTextExtractionStatus: projectedStatus
            ),
            revisionState: [
                record.revision,
                String(record.quickIdentity.byteCount),
                String(record.quickIdentity.modificationSeconds),
                String(record.quickIdentity.modificationNanoseconds),
                record.status.rawValue,
                String(PDFSearchIndexContract.extractorVersion),
                String(PDFSearchIndexContract.normalizerVersion),
                String(PDFSearchIndexContract.classifierVersion),
                String(PDFSearchIndexContract.sensitivePolicyVersion),
            ].joined(separator: ":"),
            candidateLimited: candidateLimited,
            titleTruncated: record.titleTruncated
        )
    }

    private func refresh(
        target: ReadableFileTarget,
        quick: PDFIndexQuickIdentity,
        includePages: Bool
    ) async throws -> PDFIndexDocumentRecord {
        let operation: @Sendable () async throws -> PDFIndexDocumentRecord = {
            if let existing = try await self.existingUsableRecord(
                path: target.relativePath,
                quick: quick,
                needsContent: includePages
            ) {
                return existing
            }
            let captured: (String, PDFIndexQuickIdentity, IndexedPDFExtraction)
            do {
                captured = try await self.admission.withPermit {
                    self.extractionObserver?()
                    let snapshot = try VaultFileInspector.temporarySnapshot(
                        target,
                        maximumBytes: self.configuration
                            .maximumIndexedSourceFileBytes
                    )
                    defer { snapshot.remove() }
                    let extraction = try PDFIndexExtractor.extract(
                        snapshotURL: snapshot.url,
                        path: target.relativePath,
                        includePages: includePages,
                        configuration: self.configuration.extraction
                    )
                    return (
                        snapshot.revision.rawValue,
                        PDFIndexQuickIdentity(metadata: snapshot.metadata),
                        extraction
                    )
                }
            } catch let violation as SensitiveContentPolicy.Violation {
                try await self.remove(path: target.relativePath)
                throw violation
            }
            let current = try VaultFileInspector.stableMetadata(
                target,
                vaultRoot: self.vaultRoot
            )
            guard PDFIndexQuickIdentity(metadata: current) == captured.1 else {
                throw BoundedFileReader.ReadError.changedDuringRead
            }
            return try await self.publish(
                path: target.relativePath,
                revision: captured.0,
                quick: captured.1,
                extraction: captured.2
            )
        }
        if let writerLock {
            return try await writerLock.withLock(.exclusive, operation: operation)
        }
        return try await operation()
    }

    private func existingUsableRecord(
        path: String,
        quick: PDFIndexQuickIdentity,
        needsContent: Bool
    ) throws -> PDFIndexDocumentRecord? {
        let record = try database().record(path: path)
        return isUsable(record, quick: quick, needsContent: needsContent)
            ? record : nil
    }

    private func publish(
        path: String,
        revision: String,
        quick: PDFIndexQuickIdentity,
        extraction: IndexedPDFExtraction
    ) throws -> PDFIndexDocumentRecord {
        let published = try database().publish(
            path: path,
            revision: revision,
            quickIdentity: quick,
            extraction: extraction
        )
        fuzzyTermCache.removeAll(keepingCapacity: true)
        fuzzyCacheGeneration = nil
        return published
    }

    private func remove(path: String) throws {
        try database().remove(path: path)
        fuzzyTermCache.removeAll(keepingCapacity: true)
        fuzzyCacheGeneration = nil
    }

    private func isUsable(
        _ record: PDFIndexDocumentRecord?,
        quick: PDFIndexQuickIdentity,
        needsContent: Bool
    ) -> Bool {
        guard let record, record.quickIdentity == quick else { return false }
        if needsContent, record.status == .metadataOnly { return false }
        return true
    }

    private func ftsExpression(terms: [String], phrase: Bool) -> FTSExpression? {
        guard !terms.isEmpty else { return nil }
        if phrase {
            return FTSExpression(
                value: "\"" + terms.joined(separator: " ") + "\"",
                limited: false
            )
        }
        let maximumExpressionBytes = 16 * 1_024
        var retained: [String] = []
        var byteCount = 0
        for term in terms {
            let fragment = "\"\(term)\""
            let addedBytes = fragment.utf8.count + (retained.isEmpty ? 0 : 4)
            guard byteCount + addedBytes <= maximumExpressionBytes else {
                return FTSExpression(
                    value: retained.joined(separator: " OR "),
                    limited: true
                )
            }
            retained.append(fragment)
            byteCount += addedBytes
        }
        return FTSExpression(
            value: retained.joined(separator: " OR "),
            limited: false
        )
    }

    private func fuzzyTerms(
        for queryTokens: [SearchToken],
        database db: PDFSearchIndexDatabase
    ) throws -> FuzzyExpansion {
        let generation = try db.generation()
        if fuzzyCacheGeneration != generation {
            fuzzyTermCache.removeAll(keepingCapacity: true)
            fuzzyCacheGeneration = generation
        }
        let key = queryTokens.map(\.normalized).joined(separator: "\u{1F}")
        if let cached = fuzzyTermCache[key] { return cached }
        let maximumVocabularyComparisons = 250_000
        let maximumExpandedTerms = 1_024
        var result = Set<String>()
        var comparisonCount = 0
        var workCallbacks = 0
        var limited = false
        for token in queryTokens {
            try Task.checkCancellation()
            let length = token.normalized.unicodeScalars.count
            let maximumDistance = SearchFuzzyPolicy.maximumEditDistance(
                for: token.normalized
            )
            guard maximumDistance > 0 else { continue }
            let remainingComparisons = max(
                maximumVocabularyComparisons - comparisonCount,
                0
            )
            guard remainingComparisons > 0 else {
                limited = true
                break
            }
            let remainingWork = max(
                configuration.maximumFuzzyVocabularyWorkCallbacks - workCallbacks,
                0
            )
            guard remainingWork > 0 else {
                limited = true
                break
            }
            let vocabularyBatch = try db.vocabulary(
                minimumLength: max(length - maximumDistance, 1),
                maximumLength: length + maximumDistance,
                maximum: remainingComparisons,
                maximumWorkCallbacks: remainingWork
            )
            limited = limited || vocabularyBatch.limited
            workCallbacks += vocabularyBatch.workCallbacks
            comparisonCount += vocabularyBatch.terms.count
            for (index, candidate) in vocabularyBatch.terms.enumerated() {
                if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
                if SearchFuzzyPolicy.boundedDistance(
                    token.normalized,
                    candidate,
                    maximum: maximumDistance
                ) != nil {
                    result.insert(candidate)
                    if result.count >= maximumExpandedTerms {
                        limited = true
                        break
                    }
                }
            }
            if result.count >= maximumExpandedTerms
                || workCallbacks >= configuration.maximumFuzzyVocabularyWorkCallbacks {
                limited = true
                break
            }
        }
        let value = FuzzyExpansion(terms: result.sorted(), limited: limited)
        if fuzzyTermCache.count >= 64 { fuzzyTermCache.removeAll(keepingCapacity: true) }
        fuzzyTermCache[key] = value
        return value
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func database() throws -> PDFSearchIndexDatabase {
        if let databaseStorage, databaseStorage.isCurrentFile() {
            return databaseStorage
        }
        databaseStorage = nil
        fuzzyTermCache.removeAll(keepingCapacity: true)
        fuzzyCacheGeneration = nil
        storageFullGeneration = nil
        observedDatabaseGeneration = nil
        let opened = try PDFSearchIndexDatabase(
            url: databaseURL,
            maximumDatabaseBytes: configuration.maximumDatabaseBytes,
            maximumPublicationRepresentationBytes:
                configuration.extraction.retainedRepresentationByteLimit
        )
        databaseStorage = opened
        return opened
    }
}
