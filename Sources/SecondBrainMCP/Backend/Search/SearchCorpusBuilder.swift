import CryptoKit
import Foundation

/// Enumerates and snapshots catalog-approved text notes and PDF references.
struct SearchCorpusBuilder: Sendable {
    private final class TraversalErrorCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.withLock { count += 1 }
        }

        var value: Int {
            lock.withLock { count }
        }
    }

    private struct Candidate: Sendable {
        let path: String
        let format: FileFormat
        /// Untrusted enumeration hint used only for deterministic admission order.
        let estimatedBytes: Int
    }

    private struct EnumerationResult {
        let candidates: [Candidate]
        let visitedEntryCount: Int
        let skippedFileCount: Int
        let resourceLimitedFileCount: Int
        let resourceLimitSamples: [VaultSearchResourceLimit]
        let coverageIncomplete: Bool
    }

    private let vaultPath: String
    private let store: VaultCRUDStore
    private let operations: VaultOperationCoordinator
    private let capabilities: SearchCapabilities
    private let limits: SearchResourceLimits
    private let pdfIndex: PDFSearchIndex?

    init(
        vaultPath: String,
        store: VaultCRUDStore,
        operations: VaultOperationCoordinator,
        capabilities: SearchCapabilities,
        limits: SearchResourceLimits,
        pdfIndex: PDFSearchIndex? = nil
    ) {
        self.vaultPath = vaultPath
        self.store = store
        self.operations = operations
        self.capabilities = capabilities
        self.limits = limits
        self.pdfIndex = pdfIndex
    }

    /// Builds safe immutable projections before ranking begins.
    func build(
        for request: SearchResourcePolicy.ValidatedRequest
    ) async throws -> SearchCorpus {
        let enumeration = try enumerateCandidates(for: request)
        var documents: [SearchDocument] = []
        var skippedFiles = enumeration.skippedFileCount
        var skippedSensitiveFiles = 0
        var resourceLimitedFiles = enumeration.resourceLimitedFileCount
        var partiallyLimitedPaths = Set<String>()
        var resourceLimitSamples = enumeration.resourceLimitSamples
        var aggregateBytes = 0
        var aggregateProjectionBytes = 0
        var aggregateSections = 0
        var coverageIncomplete = enumeration.coverageIncomplete
        var candidateStates: [String: String] = [:]
        var indexedPDFs: [String: PDFIndexedSearchDocument] = [:]
        var unavailableIndexedPDFPaths = Set<String>()
        var sensitiveIndexedPDFPaths = Set<String>()
        var fileByteLimitedPDFPaths = Set<String>()
        var pdfCandidateSelectionLimited = false
        var reportedPDFCandidateSelectionLimit = false

        if request.formats.contains(.pdf),
           request.fields.contains(.title) || request.fields.contains(.content) {
            var targets: [ReadableFileTarget] = []
            for candidate in enumeration.candidates where candidate.format == .pdf {
                try Task.checkCancellation()
                guard (try? candidateAncestorsRemainSearchable(candidate.path)) == true,
                      let target = try? ReadableFileTarget.resolve(
                          path: candidate.path,
                          format: .pdf,
                          vaultPath: vaultPath
                      ),
                      Self.matchesEnumeratedLocation(
                          target: target,
                          candidatePath: candidate.path,
                          vaultPath: vaultPath
                      ) else { continue }
                do {
                    try SensitiveContentPolicy.validate(
                        Data(candidate.path.utf8),
                        format: .markdown,
                        path: "search candidate path"
                    )
                    targets.append(target)
                } catch is SensitiveContentPolicy.Violation {
                    sensitiveIndexedPDFPaths.insert(candidate.path)
                }
            }
            if let pdfIndex {
                do {
                    let batch = try await pdfIndex.indexedDocuments(
                        targets: targets,
                        request: request,
                        authoritativeScopePrefix: enumeration.coverageIncomplete
                            || request.scopePrefixes.count != 1
                            ? nil : request.scopePrefixes.first
                    )
                    indexedPDFs = batch.documentsByPath
                    unavailableIndexedPDFPaths = batch.unavailablePaths
                    sensitiveIndexedPDFPaths.formUnion(batch.sensitivePaths)
                    fileByteLimitedPDFPaths.formUnion(batch.fileByteLimitedPaths)
                    pdfCandidateSelectionLimited = batch.candidateLimited
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    unavailableIndexedPDFPaths.formUnion(targets.map(\.relativePath))
                }
            } else {
                unavailableIndexedPDFPaths.formUnion(targets.map(\.relativePath))
            }
        }

        for candidate in enumeration.candidates {
            try Task.checkCancellation()
            do {
                guard try candidateAncestorsRemainSearchable(candidate.path) else {
                    coverageIncomplete = true
                    continue
                }
            } catch {
                coverageIncomplete = true
                continue
            }
            let target: ReadableFileTarget
            do {
                target = try ReadableFileTarget.resolve(
                    path: candidate.path,
                    format: candidate.format,
                    vaultPath: vaultPath
                )
            } catch {
                skippedFiles += 1
                coverageIncomplete = true
                continue
            }
            // Broad search does not follow contained symlinks. The preflight
            // above can race with path resolution: a regular candidate could
            // briefly become a symlink to another in-vault file and then be
            // restored before the post-snapshot check. Bind the resolved URL
            // to the enumerated lexical location before any bytes are read.
            guard Self.matchesEnumeratedLocation(
                target: target,
                candidatePath: candidate.path,
                vaultPath: vaultPath
            ) else {
                coverageIncomplete = true
                continue
            }

            do {
                try SensitiveContentPolicy.validate(
                    Data(candidate.path.utf8),
                    format: .markdown,
                    path: "search candidate path"
                )
            } catch is SensitiveContentPolicy.Violation {
                skippedSensitiveFiles += 1
                coverageIncomplete = true
                continue
            }

            // A pure path query is fully answerable from the validated current
            // descriptor for every supported format. It must not snapshot,
            // parse, or inherit unrelated body/title coverage failures.
            if request.fields == Set([SearchField.path]) {
                do {
                    try VaultFileInspector.validateSearchableDescriptor(
                        target,
                        vaultRoot: URL(fileURLWithPath: vaultPath)
                    )
                } catch {
                    skippedFiles += 1
                    coverageIncomplete = true
                    candidateStates[candidate.path] = "descriptor_rejected"
                    continue
                }
                let boundedTitle = PDFDisplayText.bounded(
                    MarkdownSupport.titleFromFilename(
                        (candidate.path as NSString).lastPathComponent
                    ),
                    maximumCharacters: limits.maximumMetadataCharacters,
                    maximumBytes: limits.maximumMetadataBytes
                )
                let document = SearchDocument(
                    path: candidate.path,
                    format: candidate.format,
                    title: boundedTitle.value,
                    tags: [],
                    sections: [],
                    pdfTextExtractionStatus: candidate.format == .pdf
                        ? .metadataOnly : nil
                )
                let retainedBytes = projectionByteCount(document)
                guard retainedBytes <= max(
                    limits.maximumAggregateProjectionBytes
                        - aggregateProjectionBytes,
                    0
                ) else {
                    resourceLimitedFiles += 1
                    coverageIncomplete = true
                    continue
                }
                documents.append(document)
                aggregateProjectionBytes += retainedBytes
                candidateStates[candidate.path] = "path_descriptor"
                continue
            }

            if candidate.format == .pdf,
               request.fields.contains(.title)
                || request.fields.contains(.content) {
                if sensitiveIndexedPDFPaths.contains(candidate.path) {
                    skippedSensitiveFiles += 1
                    coverageIncomplete = true
                    candidateStates[candidate.path] = "sensitive"
                    continue
                }
                guard !unavailableIndexedPDFPaths.contains(candidate.path),
                      let indexed = indexedPDFs[candidate.path] else {
                    let title = PDFDisplayText.bounded(
                        MarkdownSupport.titleFromFilename(
                            (candidate.path as NSString).lastPathComponent
                        ),
                        maximumCharacters: limits.maximumMetadataCharacters,
                        maximumBytes: limits.maximumMetadataBytes
                    ).value
                    documents.append(SearchDocument(
                        path: candidate.path,
                        format: .pdf,
                        title: title,
                        tags: [],
                        sections: [],
                        pdfTextExtractionStatus: fileByteLimitedPDFPaths
                            .contains(candidate.path)
                            ? .contentSkippedFileBytes : .indexUnavailable
                    ))
                    candidateStates[candidate.path] = "index_unavailable"
                    if request.fields.contains(.title) || request.fields.contains(.content) {
                        resourceLimitedFiles += 1
                        coverageIncomplete = true
                        partiallyLimitedPaths.insert(candidate.path)
                        if let sample = try SearchResourceDiagnostics.sample(
                            path: candidate.path,
                            reason: fileByteLimitedPDFPaths.contains(candidate.path)
                                ? .fileBytes : .projection,
                            impact: .partial
                        ) {
                            resourceLimitSamples = SearchResourceDiagnostics.merged(
                                resourceLimitSamples,
                                [sample]
                            )
                        }
                    }
                    continue
                }
                let retainedBytes = projectionByteCount(indexed.document)
                let remainingProjection = max(
                    limits.maximumAggregateProjectionBytes
                        - aggregateProjectionBytes,
                    0
                )
                let remainingSections = max(
                    limits.maximumAggregateSections - aggregateSections,
                    0
                )
                guard retainedBytes <= remainingProjection,
                      indexed.document.sections.count <= remainingSections else {
                    resourceLimitedFiles += 1
                    coverageIncomplete = true
                    partiallyLimitedPaths.insert(candidate.path)
                    let metadata = SearchDocument(
                        path: indexed.document.path,
                        format: .pdf,
                        title: indexed.document.title,
                        tags: [],
                        sections: [],
                        pdfTextExtractionStatus: .partial
                    )
                    let metadataBytes = projectionByteCount(metadata)
                    if metadataBytes <= remainingProjection {
                        documents.append(metadata)
                        aggregateProjectionBytes += metadataBytes
                    }
                    if let sample = try SearchResourceDiagnostics.sample(
                        path: candidate.path,
                        reason: .projection,
                        impact: .partial
                    ) {
                        resourceLimitSamples = SearchResourceDiagnostics.merged(
                            resourceLimitSamples,
                            [sample]
                        )
                    }
                    continue
                }
                documents.append(indexed.document)
                aggregateProjectionBytes += retainedBytes
                aggregateSections += indexed.document.sections.count
                candidateStates[candidate.path] = "index:\(indexed.revisionState)"
                let contentIncomplete = request.fields.contains(.content)
                    && indexed.document.pdfTextExtractionStatus != .extracted
                    && indexed.document.pdfTextExtractionStatus != .noExtractableText
                let titleIncomplete = request.fields.contains(.title)
                    && (indexed.titleTruncated
                        || indexed.document.pdfTextExtractionStatus == .cannotOpen)
                let globalCandidateLimit = pdfCandidateSelectionLimited
                    && !reportedPDFCandidateSelectionLimit
                if globalCandidateLimit { reportedPDFCandidateSelectionLimit = true }
                if contentIncomplete || titleIncomplete || indexed.candidateLimited
                    || globalCandidateLimit {
                    resourceLimitedFiles += 1
                    coverageIncomplete = true
                    partiallyLimitedPaths.insert(candidate.path)
                    if let sample = try SearchResourceDiagnostics.sample(
                        path: candidate.path,
                        reason: .projection,
                        impact: .partial
                    ) {
                        resourceLimitSamples = SearchResourceDiagnostics.merged(
                            resourceLimitSamples,
                            [sample]
                        )
                    }
                }
                continue
            }

            // PDF heading/tag/path projections are fully answerable from the
            // validated catalog path. Without title or content in the request,
            // do not snapshot the file or ask PDFKit to open page data.
            if candidate.format == .pdf,
               !request.fields.contains(.title),
               !request.fields.contains(.content) {
                do {
                    try VaultFileInspector.validateSearchableDescriptor(
                        target,
                        vaultRoot: URL(fileURLWithPath: vaultPath)
                    )
                } catch {
                    coverageIncomplete = true
                    candidateStates[candidate.path] = "descriptor_rejected"
                    continue
                }
                let extracted = PDFSearchDocumentExtractor.metadataOnly(
                    path: candidate.path,
                    status: .metadataOnly,
                    maximumMetadataCharacters: limits.maximumMetadataCharacters,
                    maximumMetadataBytes: limits.maximumMetadataBytes
                )
                let retainedBytes = projectionByteCount(extracted.document)
                let remainingProjection = max(
                    limits.maximumAggregateProjectionBytes
                        - aggregateProjectionBytes,
                    0
                )
                let remainingSections = max(
                    limits.maximumAggregateSections - aggregateSections,
                    0
                )
                guard retainedBytes <= remainingProjection,
                      extracted.document.sections.count <= remainingSections else {
                    resourceLimitedFiles += 1
                    coverageIncomplete = true
                    if let sample = try SearchResourceDiagnostics.sample(
                        path: candidate.path,
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
                documents.append(extracted.document)
                aggregateProjectionBytes += retainedBytes
                candidateStates[candidate.path] = "metadata_only"
                continue
            }

            let remaining = max(limits.maximumAggregateBytes - aggregateBytes, 0)
            let searchFileLimit = candidate.format == .pdf
                ? limits.maximumPDFFileBytes : limits.maximumFileBytes
            let perFileLimit = min(remaining, searchFileLimit)
            let snapshot: FileSnapshot
            do {
                snapshot = try await operations.withRead(target: target) {
                    try await store.snapshot(
                        target,
                        maximumBytes: perFileLimit,
                        rejectHiddenComponents: true
                    )
                }
            } catch is FileResourcePolicy.Violation {
                let contentIsRequested = request.fields.contains(.content)
                let titleIsRequested = request.fields.contains(.title)
                let reason: VaultSearchResourceLimitReason = remaining
                    < min(candidate.format.maximumFileBytes, searchFileLimit)
                    ? .corpusBytes : .fileBytes
                candidateStates[candidate.path] = "resource:\(reason.rawValue)"
                var retainedPDFMetadata = false
                if candidate.format == .pdf {
                    let metadata = PDFSearchDocumentExtractor.metadataOnly(
                        path: candidate.path,
                        status: .contentSkippedFileBytes,
                        maximumMetadataCharacters: limits.maximumMetadataCharacters,
                        maximumMetadataBytes: limits.maximumMetadataBytes
                    ).document
                    let retainedBytes = projectionByteCount(metadata)
                    let remainingProjection = max(
                        limits.maximumAggregateProjectionBytes
                            - aggregateProjectionBytes,
                        0
                    )
                    if retainedBytes <= remainingProjection {
                        documents.append(metadata)
                        aggregateProjectionBytes += retainedBytes
                        retainedPDFMetadata = true
                    }
                }
                if contentIsRequested || titleIsRequested
                    || candidate.format != .pdf {
                    resourceLimitedFiles += 1
                    coverageIncomplete = true
                    if retainedPDFMetadata {
                        partiallyLimitedPaths.insert(candidate.path)
                    }
                }
                let diagnosticReason: VaultSearchResourceLimitReason =
                    candidate.format == .pdf && !retainedPDFMetadata
                        ? .projection : reason
                if (contentIsRequested || titleIsRequested
                    || candidate.format != .pdf),
                   let sample = try SearchResourceDiagnostics.sample(
                    path: candidate.path,
                    reason: diagnosticReason,
                    impact: retainedPDFMetadata ? .partial : .omitted
                ) {
                    resourceLimitSamples = SearchResourceDiagnostics.merged(
                        resourceLimitSamples,
                        [sample]
                    )
                }
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                candidateStates[candidate.path] = "snapshot_failed"
                skippedFiles += 1
                coverageIncomplete = true
                continue
            }

            do {
                guard try candidateAncestorsRemainSearchable(candidate.path) else {
                    coverageIncomplete = true
                    continue
                }
            } catch {
                coverageIncomplete = true
                continue
            }

            guard snapshot.data.count <= remaining else {
                resourceLimitedFiles += 1
                coverageIncomplete = true
                if let sample = try SearchResourceDiagnostics.sample(
                    path: candidate.path,
                    reason: .corpusBytes,
                    impact: .omitted
                ) {
                    resourceLimitSamples = SearchResourceDiagnostics.merged(
                        resourceLimitSamples,
                        [sample]
                    )
                }
                continue
            }
            aggregateBytes += snapshot.data.count
            candidateStates[candidate.path] = "revision:\(snapshot.revision.rawValue)"

            do {
                let remainingProjectionBeforeExtraction = max(
                    limits.maximumAggregateProjectionBytes
                        - aggregateProjectionBytes,
                    0
                )
                let remainingSectionsBeforeExtraction = max(
                    limits.maximumAggregateSections - aggregateSections,
                    0
                )
                // Read one section beyond the remaining aggregate allowance so
                // an oversized early file can be rejected without consuming the
                // budget needed by a later file that actually fits.
                let sectionProbeLimit = min(
                    limits.maximumSectionsPerFile,
                    remainingSectionsBeforeExtraction == 0
                        ? 0 : remainingSectionsBeforeExtraction + 1
                )
                let extracted: ExtractedSearchDocument
                if candidate.format == .pdf,
                   request.fields.contains(.title),
                   !request.fields.contains(.content) {
                    extracted = try PDFSearchDocumentExtractor.extractMetadata(
                        data: snapshot.data,
                        path: candidate.path,
                        maximumMetadataCharacters: limits.maximumMetadataCharacters,
                        maximumMetadataBytes: limits.maximumMetadataBytes
                    )
                } else {
                    extracted = try SearchDocumentExtractor.extract(
                        data: snapshot.data,
                        path: candidate.path,
                        format: candidate.format,
                        maximumSections: sectionProbeLimit,
                        maximumMarkdownLines: limits.maximumMarkdownLines,
                        maximumFrontMatterLines: limits.maximumFrontMatterLines,
                        maximumTags: limits.maximumTags,
                        maximumAggregateTagBytes: limits.maximumAggregateTagBytes,
                        maximumMetadataCharacters: limits.maximumMetadataCharacters,
                        maximumMetadataBytes: limits.maximumMetadataBytes,
                        maximumStructuredValues: limits.maximumStructuredValuesPerFile,
                        maximumPDFPages: min(
                            limits.maximumPDFPagesPerFile,
                            sectionProbeLimit
                        ),
                        maximumPDFTextBytes: min(
                            limits.maximumPDFTextBytesPerFile,
                            remainingProjectionBeforeExtraction
                        )
                    )
                }
                let retainedBytes = projectionByteCount(extracted.document)
                let remainingProjection = max(
                    limits.maximumAggregateProjectionBytes
                        - aggregateProjectionBytes,
                    0
                )
                let remainingSections = max(
                    limits.maximumAggregateSections - aggregateSections,
                    0
                )
                guard retainedBytes <= remainingProjection,
                      extracted.document.sections.count <= remainingSections else {
                    let contentIsRequested = request.fields.contains(.content)
                    var retainedMetadata = false
                    if candidate.format == .pdf {
                        let metadata = SearchDocument(
                            path: extracted.document.path,
                            format: .pdf,
                            title: extracted.document.title,
                            tags: [],
                            sections: [],
                            pdfTextExtractionStatus: .partial
                        )
                        let metadataBytes = projectionByteCount(metadata)
                        if metadataBytes <= remainingProjection {
                            documents.append(metadata)
                            aggregateProjectionBytes += metadataBytes
                            retainedMetadata = true
                        }
                    }
                    if contentIsRequested || !retainedMetadata {
                        resourceLimitedFiles += 1
                        coverageIncomplete = true
                        if retainedMetadata {
                            partiallyLimitedPaths.insert(candidate.path)
                        }
                        if let sample = try SearchResourceDiagnostics.sample(
                            path: candidate.path,
                            reason: .projection,
                            impact: retainedMetadata ? .partial : .omitted
                        ) {
                            resourceLimitSamples = SearchResourceDiagnostics.merged(
                                resourceLimitSamples,
                                [sample]
                            )
                        }
                    }
                    continue
                }
                aggregateProjectionBytes += retainedBytes
                aggregateSections += extracted.document.sections.count
                documents.append(extracted.document)
                if !extracted.truncatedFields.isDisjoint(with: request.fields) {
                    resourceLimitedFiles += 1
                    partiallyLimitedPaths.insert(candidate.path)
                    coverageIncomplete = true
                    if let sample = try SearchResourceDiagnostics.sample(
                        path: candidate.path,
                        reason: .projection,
                        impact: .partial
                    ) {
                        resourceLimitSamples = SearchResourceDiagnostics.merged(
                            resourceLimitSamples,
                            [sample]
                        )
                    }
                }
            } catch is SensitiveContentPolicy.Violation {
                skippedSensitiveFiles += 1
                coverageIncomplete = true
            } catch is FileResourcePolicy.Violation {
                resourceLimitedFiles += 1
                coverageIncomplete = true
                if let sample = try SearchResourceDiagnostics.sample(
                    path: candidate.path,
                    reason: .projection,
                    impact: .omitted
                ) {
                    resourceLimitSamples = SearchResourceDiagnostics.merged(
                        resourceLimitSamples,
                        [sample]
                    )
                }
            } catch is SearchDocumentExtractor.ResourceLimit {
                resourceLimitedFiles += 1
                coverageIncomplete = true
                if let sample = try SearchResourceDiagnostics.sample(
                    path: candidate.path,
                    reason: .projection,
                    impact: .omitted
                ) {
                    resourceLimitSamples = SearchResourceDiagnostics.merged(
                        resourceLimitSamples,
                        [sample]
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skippedFiles += 1
                coverageIncomplete = true
            }
        }

        return SearchCorpus(
            documents: documents,
            revisionFingerprint: revisionFingerprint(
                candidates: enumeration.candidates,
                states: candidateStates
            ),
            skippedFileCount: skippedFiles,
            skippedSensitiveFileCount: skippedSensitiveFiles,
            resourceLimitedFileCount: resourceLimitedFiles,
            partiallyLimitedPaths: partiallyLimitedPaths,
            resourceLimitSamples: resourceLimitSamples,
            coverageIncomplete: coverageIncomplete
        )
    }

    private func enumerateCandidates(
        for request: SearchResourcePolicy.ValidatedRequest
    ) throws -> EnumerationResult {
        var candidates: [Candidate] = []
        var visitedEntries = 0
        var skippedFiles = 0
        var resourceLimitedFiles = 0
        var resourceLimitSamples: [VaultSearchResourceLimit] = []
        var coverageIncomplete = false

        for pathPrefix in request.scopePrefixes {
            guard let area = VaultArea(rawValue: String(
                pathPrefix.prefix { $0 != "/" }
            )) else {
                coverageIncomplete = true
                continue
            }
            let formats = request.formats.intersection(capabilities.formats(in: area))
            guard !formats.isEmpty else { continue }
            let remainingEntries = max(
                limits.maximumDirectoryEntries - visitedEntries,
                0
            )
            if remainingEntries == 0 {
                coverageIncomplete = true
                continue
            }
            let remainingFiles = max(limits.maximumFiles - candidates.count, 0)
            let scoped = try enumerateScope(
                pathPrefix: pathPrefix,
                formats: formats,
                maximumDirectoryEntries: remainingEntries,
                maximumFiles: remainingFiles
            )
            candidates.append(contentsOf: scoped.candidates)
            visitedEntries += scoped.visitedEntryCount
            skippedFiles += scoped.skippedFileCount
            resourceLimitedFiles += scoped.resourceLimitedFileCount
            resourceLimitSamples = SearchResourceDiagnostics.merged(
                resourceLimitSamples,
                scoped.resourceLimitSamples
            )
            coverageIncomplete = coverageIncomplete || scoped.coverageIncomplete
        }
        return EnumerationResult(
            candidates: candidates,
            visitedEntryCount: visitedEntries,
            skippedFileCount: skippedFiles,
            resourceLimitedFileCount: resourceLimitedFiles,
            resourceLimitSamples: resourceLimitSamples,
            coverageIncomplete: coverageIncomplete
        )
    }

    private func enumerateScope(
        pathPrefix: String,
        formats: Set<FileFormat>,
        maximumDirectoryEntries: Int,
        maximumFiles: Int
    ) throws -> EnumerationResult {
        let scopeURL = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent(pathPrefix, isDirectory: true)
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .fileSizeKey,
        ]
        let scopeAttributes: [FileAttributeKey: Any]
        guard !PathValidator.containsSymbolicLinkComponent(
            relativePath: pathPrefix,
            root: vaultPath
        ) else {
            return EnumerationResult(
                candidates: [],
                visitedEntryCount: 0,
                skippedFileCount: 0,
                resourceLimitedFileCount: 0,
                resourceLimitSamples: [],
                coverageIncomplete: true
            )
        }
        do {
            scopeAttributes = try FileManager.default.attributesOfItem(
                atPath: scopeURL.path
            )
        } catch {
            let cocoa = error as NSError
            let isMissing = (
                cocoa.domain == NSCocoaErrorDomain
                    && (cocoa.code == NSFileNoSuchFileError
                        || cocoa.code == NSFileReadNoSuchFileError)
            ) || (
                cocoa.domain == NSPOSIXErrorDomain
                    && cocoa.code == Int(POSIXError.Code.ENOENT.rawValue)
            )
            return EnumerationResult(
                candidates: [],
                visitedEntryCount: 0,
                skippedFileCount: 0,
                resourceLimitedFileCount: 0,
                resourceLimitSamples: [],
                coverageIncomplete: !isMissing
            )
        }
        let scopeType = scopeAttributes[.type] as? FileAttributeType
        if scopeType == .typeSymbolicLink {
            return EnumerationResult(
                candidates: [],
                visitedEntryCount: 0,
                skippedFileCount: 0,
                resourceLimitedFileCount: 0,
                resourceLimitSamples: [],
                coverageIncomplete: true
            )
        }
        guard scopeType == .typeDirectory else {
            return EnumerationResult(
                candidates: [],
                visitedEntryCount: 0,
                skippedFileCount: 0,
                resourceLimitedFileCount: 0,
                resourceLimitSamples: [],
                coverageIncomplete: true
            )
        }
        do {
            guard try !containsForbiddenScopeComponent(pathPrefix) else {
                return EnumerationResult(
                    candidates: [],
                    visitedEntryCount: 0,
                    skippedFileCount: 0,
                    resourceLimitedFileCount: 0,
                    resourceLimitSamples: [],
                    coverageIncomplete: true
                )
            }
            let scopeValues = try scopeURL.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey,
            ])
            guard scopeValues.isDirectory == true,
                  scopeValues.isSymbolicLink != true,
                  scopeValues.isHidden != true,
                  scopeValues.isPackage != true else {
                return EnumerationResult(
                    candidates: [],
                    visitedEntryCount: 0,
                    skippedFileCount: 0,
                    resourceLimitedFileCount: 0,
                    resourceLimitSamples: [],
                    coverageIncomplete: true
                )
            }
        } catch {
            return EnumerationResult(
                candidates: [],
                visitedEntryCount: 0,
                skippedFileCount: 0,
                resourceLimitedFileCount: 0,
                resourceLimitSamples: [],
                coverageIncomplete: true
            )
        }
        let traversalErrors = TraversalErrorCounter()
        guard let enumerator = FileManager.default.enumerator(
            at: scopeURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                traversalErrors.record()
                return true
            }
        ) else {
            return EnumerationResult(
                candidates: [],
                visitedEntryCount: 0,
                skippedFileCount: 0,
                resourceLimitedFileCount: 0,
                resourceLimitSamples: [],
                coverageIncomplete: true
            )
        }

        var candidates: [Candidate] = []
        let initiallyCountedTraversalErrors = traversalErrors.value
        var skipped = 0
        var visited = 0
        var coverageIncomplete = initiallyCountedTraversalErrors > 0

        while let url = enumerator.nextObject() as? URL {
            if visited.isMultiple(of: 128) { try Task.checkCancellation() }
            visited += 1
            if visited > maximumDirectoryEntries {
                coverageIncomplete = true
                break
            }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                coverageIncomplete = true
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }

            // DirectoryEnumerator.level gives a root-relative component count
            // even when Foundation canonicalizes a system alias in yielded URLs
            // (for example /var -> /private/var). This derives only a candidate;
            // ReadableFileTarget remains the containment authority before open.
            let depth = enumerator.level
            guard depth > 0, url.pathComponents.count >= depth else {
                coverageIncomplete = true
                continue
            }
            let suffix = url.pathComponents.suffix(depth).joined(separator: "/")
            let relativePath = pathPrefix + suffix
            let ext = url.pathExtension.lowercased()
            guard let format = FileFormat.allCases.first(where: {
                $0.extensions.contains(ext)
            }), formats.contains(format) else { continue }
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current {
                skipped += 1
                continue
            }

            candidates.append(Candidate(
                path: relativePath,
                format: format,
                estimatedBytes: max(values.fileSize ?? 0, 0)
            ))
        }

        // Favor ordinary notes and smaller evidence files so a few large HARs
        // cannot consume the entire live-search corpus. The descriptor snapshot
        // remains the size and containment authority; this hint affects order only.
        candidates.sort {
            let lhs = admissionKey($0)
            let rhs = admissionKey($1)
            if lhs.format != rhs.format { return lhs.format < rhs.format }
            if lhs.bytes != rhs.bytes { return lhs.bytes < rhs.bytes }
            return $0.path < $1.path
        }
        if traversalErrors.value > initiallyCountedTraversalErrors {
            coverageIncomplete = true
        }
        if skipped > 0 { coverageIncomplete = true }
        let maximumFiles = max(maximumFiles, 0)
        var resourceLimitedFiles = 0
        var resourceLimitSamples: [VaultSearchResourceLimit] = []
        if candidates.count > maximumFiles {
            resourceLimitedFiles = candidates.count - maximumFiles
            for candidate in candidates.dropFirst(maximumFiles) {
                guard let sample = try SearchResourceDiagnostics.sample(
                    path: candidate.path,
                    reason: .fileCount,
                    impact: .omitted
                ) else { continue }
                resourceLimitSamples = SearchResourceDiagnostics.merged(
                    resourceLimitSamples,
                    [sample]
                )
            }
            candidates = Array(candidates.prefix(maximumFiles))
            coverageIncomplete = true
        }
        return EnumerationResult(
            candidates: candidates,
            visitedEntryCount: min(visited, maximumDirectoryEntries),
            skippedFileCount: skipped,
            resourceLimitedFileCount: resourceLimitedFiles,
            resourceLimitSamples: resourceLimitSamples,
            coverageIncomplete: coverageIncomplete
        )
    }

    private func admissionKey(_ candidate: Candidate) -> (format: Int, bytes: Int) {
        let priority: Int
        switch candidate.format {
        case .markdown: priority = 0
        case .canvas, .json, .csv, .patch, .log: priority = 1
        case .har: priority = 2
        default: priority = 3
        }
        return (priority, candidate.estimatedBytes)
    }

    /// Conservative retained UTF-8 payload size for one immutable projection.
    /// Structural object counts are independently capped by the extractor.
    private func projectionByteCount(_ document: SearchDocument) -> Int {
        var total = 0
        func add(_ value: String?) {
            guard let value else { return }
            let (sum, overflow) = total.addingReportingOverflow(value.utf8.count)
            total = overflow ? Int.max : sum
        }
        add(document.path)
        add(document.title)
        document.tags.forEach { add($0) }
        for section in document.sections {
            add(section.heading)
            add(section.content)
            add(section.location?.nodeID)
            add(section.location?.nodeType)
            add(section.location?.field)
            add(section.printedPage)
        }
        return total
    }

    private func revisionFingerprint(
        candidates: [Candidate],
        states: [String: String]
    ) -> String {
        let facts = candidates.sorted { $0.path < $1.path }.map { candidate in
            [
                candidate.path,
                candidate.format.rawValue,
                String(candidate.estimatedBytes),
                states[candidate.path] ?? "not_admitted",
            ].joined(separator: "\u{001E}")
        }.joined(separator: "\u{001F}")
        return SHA256.hash(data: Data(facts.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Rechecks every scoped ancestor after request validation and immediately
    /// before traversal, closing the absent-prefix-to-hidden/package race.
    private func containsForbiddenScopeComponent(
        _ relativePath: String
    ) throws -> Bool {
        var url = URL(fileURLWithPath: vaultPath)
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: true)
            let values = try url.resourceValues(forKeys: [
                .isHiddenKey, .isPackageKey, .isSymbolicLinkKey,
            ])
            if values.isHidden == true
                || values.isPackage == true
                || values.isSymbolicLink == true {
                return true
            }
        }
        return false
    }

    /// Rechecks a yielded candidate's ancestors immediately before and after
    /// its stable descriptor snapshot so a raced scope cannot silently enter
    /// the searchable corpus.
    private func candidateAncestorsRemainSearchable(
        _ relativePath: String
    ) throws -> Bool {
        // Unlike generic explicit reads, broad search never follows even a
        // contained final symlink because that could escape the requested
        // area or prefix while retaining the enumerated display path.
        guard !PathValidator.containsSymbolicLinkComponent(
            relativePath: relativePath,
            root: vaultPath
        ) else { return false }
        let parent = (relativePath as NSString).deletingLastPathComponent + "/"
        return try !containsForbiddenScopeComponent(parent)
    }

    /// Confirms resolution did not follow a candidate or parent symlink.
    ///
    /// Only the vault root is canonicalized. Resolving the appended candidate
    /// would erase the very distinction this check is intended to preserve.
    static func matchesEnumeratedLocation(
        target: ReadableFileTarget,
        candidatePath: String,
        vaultPath: String
    ) -> Bool {
        let canonicalRoot = URL(fileURLWithPath: vaultPath)
            .standardized
            .resolvingSymlinksInPath()
        let expected = canonicalRoot
            .appendingPathComponent(candidatePath)
            .standardized
        return target.url.standardized.path == expected.path
    }
}
