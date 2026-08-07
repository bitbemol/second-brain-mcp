import Foundation

/// Enumerates and snapshots only catalog-approved textual notes.
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
    }

    private struct EnumerationResult {
        let candidates: [Candidate]
        let skippedFileCount: Int
        let resourceLimitedFileCount: Int
        let coverageIncomplete: Bool
    }

    private let vaultPath: String
    private let store: VaultCRUDStore
    private let operations: VaultOperationCoordinator
    private let limits: SearchResourceLimits

    init(
        vaultPath: String,
        store: VaultCRUDStore,
        operations: VaultOperationCoordinator,
        limits: SearchResourceLimits
    ) {
        self.vaultPath = vaultPath
        self.store = store
        self.operations = operations
        self.limits = limits
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
        var aggregateBytes = 0
        var coverageIncomplete = enumeration.coverageIncomplete

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

            let remaining = max(limits.maximumAggregateBytes - aggregateBytes, 0)
            let snapshot: FileSnapshot
            do {
                snapshot = try await operations.withRead(target: target) {
                    try await store.snapshot(target, maximumBytes: remaining)
                }
            } catch is FileResourcePolicy.Violation {
                resourceLimitedFiles += 1
                coverageIncomplete = true
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
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
                continue
            }
            aggregateBytes += snapshot.data.count

            do {
                let extracted = try SearchDocumentExtractor.extract(
                    data: snapshot.data,
                    path: candidate.path,
                    format: candidate.format,
                    maximumSections: limits.maximumSectionsPerFile,
                    maximumMarkdownLines: limits.maximumMarkdownLines,
                    maximumFrontMatterLines: limits.maximumFrontMatterLines,
                    maximumTags: limits.maximumTags,
                    maximumAggregateTagBytes: limits.maximumAggregateTagBytes,
                    maximumMetadataCharacters: limits.maximumMetadataCharacters,
                    maximumMetadataBytes: limits.maximumMetadataBytes,
                    maximumStructuredValues: limits.maximumStructuredValuesPerFile
                )
                documents.append(extracted.document)
                if !extracted.truncatedFields.isDisjoint(with: request.fields) {
                    resourceLimitedFiles += 1
                    partiallyLimitedPaths.insert(candidate.path)
                    coverageIncomplete = true
                }
            } catch is SensitiveContentPolicy.Violation {
                skippedSensitiveFiles += 1
                coverageIncomplete = true
            } catch is FileResourcePolicy.Violation {
                resourceLimitedFiles += 1
                coverageIncomplete = true
            } catch is SearchDocumentExtractor.ResourceLimit {
                resourceLimitedFiles += 1
                coverageIncomplete = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skippedFiles += 1
                coverageIncomplete = true
            }
        }

        return SearchCorpus(
            documents: documents,
            skippedFileCount: skippedFiles,
            skippedSensitiveFileCount: skippedSensitiveFiles,
            resourceLimitedFileCount: resourceLimitedFiles,
            partiallyLimitedPaths: partiallyLimitedPaths,
            coverageIncomplete: coverageIncomplete
        )
    }

    private func enumerateCandidates(
        for request: SearchResourcePolicy.ValidatedRequest
    ) throws -> EnumerationResult {
        let scopeURL = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent(request.pathPrefix, isDirectory: true)
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        let scopeAttributes: [FileAttributeKey: Any]
        guard !PathValidator.containsSymbolicLinkComponent(
            relativePath: request.pathPrefix,
            root: vaultPath
        ) else {
            return EnumerationResult(
                candidates: [],
                skippedFileCount: 0,
                resourceLimitedFileCount: 0,
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
                skippedFileCount: 0,
                resourceLimitedFileCount: 0,
                coverageIncomplete: !isMissing
            )
        }
        let scopeType = scopeAttributes[.type] as? FileAttributeType
        if scopeType == .typeSymbolicLink {
            return EnumerationResult(
                candidates: [],
                skippedFileCount: 0,
                resourceLimitedFileCount: 0,
                coverageIncomplete: true
            )
        }
        guard scopeType == .typeDirectory else {
            return EnumerationResult(
                candidates: [],
                skippedFileCount: 0,
                resourceLimitedFileCount: 0,
                coverageIncomplete: true
            )
        }
        do {
            guard try !containsForbiddenScopeComponent(request.pathPrefix) else {
                return EnumerationResult(
                    candidates: [],
                    skippedFileCount: 0,
                    resourceLimitedFileCount: 0,
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
                    skippedFileCount: 0,
                    resourceLimitedFileCount: 0,
                    coverageIncomplete: true
                )
            }
        } catch {
            return EnumerationResult(
                candidates: [],
                skippedFileCount: 0,
                resourceLimitedFileCount: 0,
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
                skippedFileCount: 0,
                resourceLimitedFileCount: 0,
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
            if visited > limits.maximumDirectoryEntries {
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
            let relativePath = request.pathPrefix + suffix
            let ext = url.pathExtension.lowercased()
            guard let format = FileFormat.allCases.first(where: {
                $0.extensions.contains(ext)
            }), request.formats.contains(format) else { continue }
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current {
                skipped += 1
                continue
            }

            candidates.append(Candidate(path: relativePath, format: format))
        }

        candidates.sort { $0.path < $1.path }
        if traversalErrors.value > initiallyCountedTraversalErrors {
            coverageIncomplete = true
        }
        if skipped > 0 { coverageIncomplete = true }
        let maximumFiles = max(limits.maximumFiles, 0)
        var resourceLimitedFiles = 0
        if candidates.count > maximumFiles {
            resourceLimitedFiles = candidates.count - maximumFiles
            candidates = Array(candidates.prefix(maximumFiles))
            coverageIncomplete = true
        }
        return EnumerationResult(
            candidates: candidates,
            skippedFileCount: skipped,
            resourceLimitedFileCount: resourceLimitedFiles,
            coverageIncomplete: coverageIncomplete
        )
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
        let parent = (relativePath as NSString).deletingLastPathComponent + "/"
        guard !PathValidator.containsSymbolicLinkComponent(
            relativePath: parent,
            root: vaultPath
        ) else { return false }
        return try !containsForbiddenScopeComponent(parent)
    }
}
