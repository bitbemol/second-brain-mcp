import Foundation

/// Bounded graph traversal over one immutable source snapshot at a time.
struct VaultLinkQueryEngine: VaultLinkQueryService, Sendable {
    private let vaultPath: String
    private let capabilities: FileCapabilities
    private let store: VaultCRUDStore
    private let access: any VaultAccessCoordinating

    init(
        vaultPath: String,
        capabilities: FileCapabilities,
        store: VaultCRUDStore,
        access: any VaultAccessCoordinating
    ) {
        self.vaultPath = vaultPath
        self.capabilities = capabilities
        self.store = store
        self.access = access
    }

    func query(_ request: LinkQueryRequest) async throws -> LinkQueryResponse {
        let request = try validate(request)
        let requestHash = try LinkQueryCursorCodec.requestHash(request)
        let cursor = try request.cursor.map {
            try LinkQueryCursorCodec.decode($0, requestHash: requestHash)
        }
        let parsed = try ObsidianWikiLinkParser.parseRequest(request.target)
        let corpus = VaultLinkCorpusBuilder(
            vaultPath: vaultPath, capabilities: capabilities, store: store
        )
        return try await access.withRead {
            let files = try corpus.files()
            let index = try VaultLinkPathIndex(files: files)
            let contextPath = try request.fromPath.map { try index.validatedContextPath($0) }
            var fingerprint = LinkQueryFingerprint()
            fingerprint.append("namespace")
            for file in files {
                try Task.checkCancellation()
                fingerprint.append(file.path)
                fingerprint.append(file.format.rawValue)
            }
            var page = LinkQueryPageAccumulator(offset: cursor?.offset ?? 0, limit: request.limit)
            var coverage = DiscoveryCoverageAccumulator()

            if request.direction == .resolve {
                let candidates = try index.resolve(parsed.resolutionTarget, fromPath: contextPath)
                for candidate in candidates {
                    try page.append(LinkQueryResult(
                        sourcePath: nil, target: parsed.target, resolvedPath: candidate.path,
                        kind: parsed.kind, alias: parsed.alias, occurrence: nil,
                        ambiguous: candidates.count > 1, resolvedFormat: candidate.format,
                        fragment: parsed.fragment
                    ))
                }
            } else {
                let selectedSource: String?
                if request.direction == .outgoing {
                    selectedSource = try index.validatedSourcePath(request.target)
                } else if let sourcePath = request.sourcePath {
                    do { selectedSource = try index.validatedSourcePath(sourcePath) }
                    catch LinkQueryError.invalidTarget { throw LinkQueryError.invalidSourcePath }
                } else {
                    selectedSource = nil
                }
                let targets = request.direction == .backlinks
                    ? Set(try index.resolve(parsed.resolutionTarget, fromPath: contextPath).map(\.path))
                    : []
                let readWork = ReadWork()
                var work = Work()
                for file in files where file.format == .markdown && file.path.hasPrefix("notes/") {
                    if let selectedSource, file.path != selectedSource { continue }
                    try Task.checkCancellation()
                    let remaining = LinkQueryExecutionLimits.maximumSourceBytes - readWork.bytes
                    guard remaining > 0 else { throw LinkQueryError.workBudgetExceeded }
                    let maximumBytes = min(remaining, file.format.maximumFileBytes)
                    var revision: String?
                    do {
                        let snapshot = try await corpus.snapshot(
                            file, maximumBytes: maximumBytes, didReadBytes: { readWork.record($0) }
                        )
                        guard readWork.bytes <= LinkQueryExecutionLimits.maximumSourceBytes else {
                            throw LinkQueryError.workBudgetExceeded
                        }
                        revision = snapshot.revision.description
                        guard let text = String(data: snapshot.data, encoding: .utf8) else {
                            throw SearchAtomProviderError.invalidUTF8(file.path)
                        }
                        // Commit neither locators nor derived identity until the complete source succeeds.
                        var provisionalPage = page
                        let derived = try process(
                            text: text, file: file, index: index, request: request,
                            targetPaths: targets, page: &provisionalPage, work: &work
                        )
                        page = provisionalPage
                        fingerprint.append("source")
                        fingerprint.append(file.path)
                        fingerprint.append(revision ?? "")
                        fingerprint.append(derived)
                    } catch {
                        try Task.checkCancellation()
                        // The bounded reader may consume one growth-detection byte past its cap.
                        // Even discarded reads consume work; overflow can never become coverage.
                        guard readWork.bytes <= LinkQueryExecutionLimits.maximumSourceBytes else {
                            throw LinkQueryError.workBudgetExceeded
                        }
                        if let limit = error as? FileResourcePolicy.Violation,
                           limit.bytes <= file.format.maximumFileBytes,
                           maximumBytes < file.format.maximumFileBytes, limit.bytes > maximumBytes {
                            throw LinkQueryError.workBudgetExceeded
                        }
                        guard let reason = DiscoveryFileFailure.reason(for: error) else { throw error }
                        coverage.record(path: file.path, reason: reason)
                        fingerprint.append("failed-source")
                        fingerprint.append(file.path)
                        fingerprint.append(reason.rawValue)
                        fingerprint.append(revision ?? "")
                    }
                }
            }
            return try page.response(
                request: request, requestHash: requestHash,
                fingerprint: fingerprint.digest, cursor: cursor, coverage: coverage.value
            )
        }
    }

    private func process(
        text: String,
        file: VaultLinkFile,
        index: VaultLinkPathIndex,
        request: LinkQueryRequest,
        targetPaths: Set<String>,
        page: inout LinkQueryPageAccumulator,
        work: inout Work
    ) throws -> String {
        var derived = LinkQueryFingerprint()
        var cache = ResolutionCache()
        var groups: [String: SourceGroup] = [:]
        let grouped = request.direction == .backlinks && (request.groupBy ?? .source) == .source
        try ObsidianWikiLinkParser.forEach(in: text) { link in
            work.occurrences += 1
            guard work.occurrences <= LinkQueryExecutionLimits.maximumOccurrences else {
                throw LinkQueryError.workBudgetExceeded
            }
            derived.append(link.target)
            derived.append(link.syntax.rawValue)
            derived.append(link.fragment ?? "")
            derived.append(link.alias ?? "")
            derived.append(link.kind.rawValue)
            derived.append(String(link.occurrence))
            guard let candidates = try cache.candidates(
                link: link, source: file.path,
                backlinks: request.direction == .backlinks, index: index
            ) else { return }
            work.candidates += candidates.count
            guard work.candidates <= LinkQueryExecutionLimits.maximumResolutionCandidates else {
                throw LinkQueryError.workBudgetExceeded
            }
            if request.direction == .outgoing, candidates.isEmpty {
                try page.append(LinkQueryResult(
                    sourcePath: file.path, target: link.target, resolvedPath: nil,
                    kind: link.kind, alias: link.alias, occurrence: link.occurrence,
                    ambiguous: false, fragment: link.fragment
                ))
            }
            for candidate in candidates {
                if request.direction == .backlinks, !targetPaths.contains(candidate.path) { continue }
                if grouped {
                    var group = groups[candidate.path] ?? SourceGroup(file: candidate)
                    if group.lastOccurrence != link.occurrence {
                        group.count += 1
                        group.lastOccurrence = link.occurrence
                    }
                    group.ambiguous = group.ambiguous || candidates.count > 1
                    groups[candidate.path] = group
                } else {
                    try page.append(LinkQueryResult(
                        sourcePath: file.path, target: link.target, resolvedPath: candidate.path,
                        kind: link.kind, alias: link.alias, occurrence: link.occurrence,
                        ambiguous: candidates.count > 1, resolvedFormat: candidate.format,
                        fragment: link.fragment
                    ))
                }
            }
        }
        for path in groups.keys.sorted() {
            try Task.checkCancellation()
            guard let group = groups[path] else { continue }
            try page.append(LinkQueryResult(
                sourcePath: file.path, resolvedPath: path, resolvedFormat: group.file.format,
                occurrenceCount: group.count, ambiguous: group.ambiguous
            ))
        }
        return derived.digest
    }

    private func validate(_ request: LinkQueryRequest) throws -> LinkQueryRequest {
        let target = request.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw LinkQueryError.emptyTarget }
        guard target.utf8.count <= LinkQueryLimits.maximumTargetBytes else {
            throw LinkQueryError.targetTooLarge(limit: LinkQueryLimits.maximumTargetBytes)
        }
        guard !target.hasPrefix("/"), !target.contains("\\"),
              !PathTraversalDetector.containsTraversal(in: target) else {
            throw LinkQueryError.invalidTarget
        }
        guard (1...LinkQueryLimits.maximumResults).contains(request.limit) else {
            throw LinkQueryError.invalidLimit(maximum: LinkQueryLimits.maximumResults)
        }
        guard request.direction == .backlinks || (request.groupBy == nil && request.sourcePath == nil) else {
            throw LinkQueryError.invalidProjection
        }
        if let from = request.fromPath, !validSourceSpelling(from) { throw LinkQueryError.invalidFromPath }
        if let source = request.sourcePath, !validSourceSpelling(source) { throw LinkQueryError.invalidSourcePath }
        return LinkQueryRequest(
            direction: request.direction, target: target, fromPath: request.fromPath,
            groupBy: request.groupBy, sourcePath: request.sourcePath,
            limit: request.limit, cursor: request.cursor
        )
    }

    private func validSourceSpelling(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= LinkQueryLimits.maximumTargetBytes
            && !path.hasPrefix("/") && !path.contains("\\")
            && !PathTraversalDetector.containsTraversal(in: path)
    }

    /// Read callbacks cross the store's nonisolated boundary; failed work is never refunded.
    private final class ReadWork: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0

        var bytes: Int { lock.withLock { total } }

        func record(_ bytes: Int) {
            lock.withLock { total += bytes }
        }
    }

    private struct Work {
        var occurrences = 0
        var candidates = 0
    }

    private struct SourceGroup {
        let file: VaultLinkFile
        var count = 0
        var lastOccurrence = 0
        var ambiguous = false
    }

    /// A bounded per-source cache; excess keys still resolve correctly without retention.
    private struct ResolutionCache {
        struct Resolution {
            let candidates: [VaultLinkFile]?
        }
        var values: [String: Resolution] = [:]
        var retainedCandidates = 0

        mutating func candidates(
            link: ParsedVaultWikiLink, source: String, backlinks: Bool, index: VaultLinkPathIndex
        ) throws -> [VaultLinkFile]? {
            let key = link.syntax.rawValue + ":" + link.resolutionTarget
            if let cached = values[key] { return cached.candidates }
            let resolved: [VaultLinkFile]?
            switch link.syntax {
            case .markdown:
                resolved = index.markdownCandidates(link.resolutionTarget, fromPath: source)
            case .wiki:
                // Stored unsafe targets remain unresolved; direct caller targets are rejected.
                do {
                    resolved = try backlinks
                        ? index.closestCandidates(link.resolutionTarget, fromPath: source)
                        : index.resolve(link.resolutionTarget, fromPath: source)
                } catch LinkQueryError.invalidTarget {
                    resolved = []
                }
            }
            let count = resolved?.count ?? 0
            if values.count < LinkQueryExecutionLimits.maximumCachedTargets,
               retainedCandidates + count <= LinkQueryExecutionLimits.maximumCachedCandidates {
                values[key] = Resolution(candidates: resolved)
                retainedCandidates += count
            }
            return resolved
        }
    }
}
