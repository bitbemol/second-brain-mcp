import Foundation

// MARK: - Vault link query

/// Bounded read-only Obsidian wiki-link query engine.
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
        let validated = try validate(request)
        let parsed = try ObsidianWikiLinkParser.parseRequest(validated.target)
        let corpusBuilder = VaultLinkCorpusBuilder(
            vaultPath: vaultPath,
            capabilities: capabilities,
            store: store
        )
        return try await access.withRead {
            let files = try corpusBuilder.files()
            let index = try VaultLinkPathIndex(files: files)
            let contextPath = try validated.fromPath.map {
                try index.validatedContextPath($0)
            }
            let results: [LinkQueryResult]
            switch validated.direction {
            case .resolve:
                results = try resolveResults(
                    parsed: parsed,
                    contextPath: contextPath,
                    index: index
                )
            case .outgoing:
                let sourcePath = try index.validatedSourcePath(validated.target)
                let documents = try await corpusBuilder.markdownDocuments(
                    from: files,
                    scope: .one(sourcePath)
                )
                guard let document = documents.first else {
                    throw LinkQueryError.invalidTarget
                }
                results = try outgoingResults(document: document, index: index)
            case .backlinks:
                let targetPaths = Set(try index.resolve(
                    parsed.target,
                    fromPath: contextPath
                ).map(\.path))
                let documents = try await corpusBuilder.markdownDocuments(
                    from: files,
                    scope: .all
                )
                results = try backlinkResults(
                    documents: documents,
                    targetPaths: targetPaths,
                    index: index
                )
            }
            guard results.count <= LinkQueryLimits.maximumMatchingResults else {
                throw LinkQueryError.resultSetTooLarge(
                    limit: LinkQueryLimits.maximumMatchingResults
                )
            }
            return try paginate(
                results,
                request: validated,
                contextPath: contextPath
            )
        }
    }

    private func validate(_ request: LinkQueryRequest) throws -> LinkQueryRequest {
        let target = request.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw LinkQueryError.emptyTarget }
        guard target.utf8.count <= LinkQueryLimits.maximumTargetBytes else {
            throw LinkQueryError.targetTooLarge(limit: LinkQueryLimits.maximumTargetBytes)
        }
        guard !target.hasPrefix("/"),
              !target.contains("\\"),
              !PathTraversalDetector.containsTraversal(in: target) else {
            throw LinkQueryError.invalidTarget
        }
        guard (1...LinkQueryLimits.maximumResults).contains(request.limit) else {
            throw LinkQueryError.invalidLimit(maximum: LinkQueryLimits.maximumResults)
        }
        if let cursor = request.cursor,
           cursor.isEmpty || cursor.utf8.count > LinkQueryLimits.maximumCursorBytes {
            throw LinkQueryError.invalidCursor
        }
        if let fromPath = request.fromPath {
            guard !fromPath.isEmpty,
                  fromPath.utf8.count <= LinkQueryLimits.maximumTargetBytes,
                  !fromPath.hasPrefix("/"),
                  !fromPath.contains("\\"),
                  !PathTraversalDetector.containsTraversal(in: fromPath) else {
                throw LinkQueryError.invalidFromPath
            }
        }
        return LinkQueryRequest(
            direction: request.direction,
            target: target,
            fromPath: request.fromPath,
            limit: request.limit,
            cursor: request.cursor
        )
    }

    private func resolveResults(
        parsed: ParsedVaultWikiLink,
        contextPath: String?,
        index: VaultLinkPathIndex
    ) throws -> [LinkQueryResult] {
        let candidates = try index.resolve(parsed.target, fromPath: contextPath)
        return candidates.map { candidate in
            LinkQueryResult(
                sourcePath: nil,
                target: parsed.target,
                resolvedPath: candidate.path,
                kind: parsed.kind,
                alias: parsed.alias,
                occurrence: nil,
                ambiguous: candidates.count > 1
            )
        }
    }

    private func outgoingResults(
        document: VaultLinkDocument,
        index: VaultLinkPathIndex
    ) throws -> [LinkQueryResult] {
        var results: [LinkQueryResult] = []
        var resolutionCache: [String: [VaultLinkFile]] = [:]
        for link in ObsidianWikiLinkParser.extract(from: document.text) {
            try Task.checkCancellation()
            let candidates: [VaultLinkFile]
            if let cached = resolutionCache[link.target] {
                candidates = cached
            } else {
                let resolved = try index.resolve(
                    link.target,
                    fromPath: document.file.path
                )
                resolutionCache[link.target] = resolved
                candidates = resolved
            }
            if candidates.isEmpty {
                results.append(LinkQueryResult(
                    sourcePath: document.file.path,
                    target: link.target,
                    resolvedPath: nil,
                    kind: link.kind,
                    alias: link.alias,
                    occurrence: link.occurrence,
                    ambiguous: false
                ))
            } else {
                for candidate in candidates {
                    results.append(LinkQueryResult(
                        sourcePath: document.file.path,
                        target: link.target,
                        resolvedPath: candidate.path,
                        kind: link.kind,
                        alias: link.alias,
                        occurrence: link.occurrence,
                        ambiguous: candidates.count > 1
                    ))
                }
            }
            try enforceResultLimit(results.count)
        }
        return results
    }

    private func backlinkResults(
        documents: [VaultLinkDocument],
        targetPaths: Set<String>,
        index: VaultLinkPathIndex
    ) throws -> [LinkQueryResult] {
        guard !targetPaths.isEmpty else { return [] }
        var results: [LinkQueryResult] = []
        for document in documents {
            try Task.checkCancellation()
            for link in ObsidianWikiLinkParser.extract(from: document.text) {
                let candidates = try index.closestCandidates(
                    link.target,
                    fromPath: document.file.path
                )
                for candidate in candidates where targetPaths.contains(candidate.path) {
                    results.append(LinkQueryResult(
                        sourcePath: document.file.path,
                        target: link.target,
                        resolvedPath: candidate.path,
                        kind: link.kind,
                        alias: link.alias,
                        occurrence: link.occurrence,
                        ambiguous: candidates.count > 1
                    ))
                }
                try enforceResultLimit(results.count)
            }
        }
        return results
    }

    private func enforceResultLimit(_ count: Int) throws {
        guard count <= LinkQueryLimits.maximumMatchingResults else {
            throw LinkQueryError.resultSetTooLarge(
                limit: LinkQueryLimits.maximumMatchingResults
            )
        }
    }

    private func paginate(
        _ results: [LinkQueryResult],
        request: LinkQueryRequest,
        contextPath: String?
    ) throws -> LinkQueryResponse {
        let requestHash = try LinkQueryCursorCodec.requestHash(
            direction: request.direction,
            target: request.target,
            fromPath: contextPath
        )
        let corpusHash = try LinkQueryCursorCodec.corpusHash(results)
        let offset: Int
        if let cursor = request.cursor {
            offset = try LinkQueryCursorCodec.decode(
                cursor,
                requestHash: requestHash,
                corpusHash: corpusHash,
                resultCount: results.count
            ).offset
        } else {
            offset = 0
        }
        let end = min(results.count, offset + request.limit)
        let page = Array(results[offset..<end])
        let nextCursor = end < results.count
            ? try LinkQueryCursorCodec.encode(
                requestHash: requestHash,
                corpusHash: corpusHash,
                offset: end
            )
            : nil
        return LinkQueryResponse(
            direction: request.direction,
            results: page,
            nextCursor: nextCursor
        )
    }
}
