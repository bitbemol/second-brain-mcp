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

    private struct AggregateLimitReached: Error, Sendable {}

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
        var searchedFiles = 0
        var skippedFiles = enumeration.skipped
        var skippedSensitiveFiles = 0
        var aggregateBytes = 0
        var truncated = enumeration.truncated

        for candidate in enumeration.candidates {
            try Task.checkCancellation()
            let target: ReadableFileTarget
            do {
                target = try ReadableFileTarget.resolve(
                    path: candidate.path,
                    format: candidate.format,
                    vaultPath: vaultPath
                )
            } catch {
                skippedFiles += 1
                continue
            }

            let remaining = limits.maximumAggregateBytes - aggregateBytes
            let snapshot: FileSnapshot
            do {
                snapshot = try await operations.withRead(target: target) {
                    let metadata = try VaultFileInspector.inspect(target)
                    guard metadata.byteCount <= remaining else {
                        throw AggregateLimitReached()
                    }
                    return try await store.snapshot(target)
                }
            } catch is AggregateLimitReached {
                truncated = true
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skippedFiles += 1
                continue
            }

            guard snapshot.data.count <= remaining else {
                truncated = true
                break
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
                    maximumMetadataBytes: limits.maximumMetadataBytes
                )
                documents.append(extracted.document)
                searchedFiles += 1
                truncated = truncated || extracted.truncated
            } catch is SensitiveContentPolicy.Violation {
                skippedSensitiveFiles += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skippedFiles += 1
            }
        }

        return SearchCorpus(
            documents: documents,
            searchedFileCount: searchedFiles,
            skippedFileCount: skippedFiles,
            skippedSensitiveFileCount: skippedSensitiveFiles,
            truncated: truncated
        )
    }

    private func enumerateCandidates(
        for request: SearchResourcePolicy.ValidatedRequest
    ) throws -> (candidates: [Candidate], skipped: Int, truncated: Bool) {
        let notesURL = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent("notes", isDirectory: true)
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        let traversalErrors = TraversalErrorCounter()
        guard let enumerator = FileManager.default.enumerator(
            at: notesURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                traversalErrors.record()
                return true
            }
        ) else {
            return ([], 0, false)
        }

        var candidates: [Candidate] = []
        let initiallyCountedTraversalErrors = traversalErrors.value
        var skipped = initiallyCountedTraversalErrors
        var visited = 0
        var truncated = false

        while let url = enumerator.nextObject() as? URL {
            if visited.isMultiple(of: 128) { try Task.checkCancellation() }
            visited += 1
            if visited > limits.maximumDirectoryEntries {
                truncated = true
                break
            }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                skipped += 1
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current {
                skipped += 1
                continue
            }

            // DirectoryEnumerator.level gives a root-relative component count
            // even when Foundation canonicalizes a system alias in yielded URLs
            // (for example /var -> /private/var). This derives only a candidate;
            // ReadableFileTarget remains the containment authority before open.
            let depth = enumerator.level
            guard depth > 0, url.pathComponents.count >= depth else {
                skipped += 1
                continue
            }
            let suffix = url.pathComponents.suffix(depth).joined(separator: "/")
            let relativePath = "notes/" + suffix
            guard relativePath.hasPrefix(request.pathPrefix) else { continue }
            let ext = url.pathExtension.lowercased()
            guard let format = FileFormat.allCases.first(where: {
                $0.extensions.contains(ext)
            }), request.formats.contains(format) else { continue }

            candidates.append(Candidate(path: relativePath, format: format))
        }

        candidates.sort { $0.path < $1.path }
        skipped += traversalErrors.value - initiallyCountedTraversalErrors
        if candidates.count > limits.maximumFiles {
            candidates = Array(candidates.prefix(limits.maximumFiles))
            truncated = true
        }
        return (candidates, skipped, truncated)
    }
}
