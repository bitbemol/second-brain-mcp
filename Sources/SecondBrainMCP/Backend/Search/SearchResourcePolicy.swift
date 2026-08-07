import Foundation

/// Deterministic ceilings for one live search request.
struct SearchResourceLimits: Sendable {
    let maximumQueryBytes: Int
    let maximumQueryTokens: Int
    let maximumTokenScalars: Int
    let maximumResults: Int
    let maximumDirectoryEntries: Int
    let maximumFiles: Int
    let maximumAggregateBytes: Int
    let maximumSectionsPerFile: Int
    let maximumMarkdownLines: Int
    let maximumFrontMatterLines: Int
    let maximumTags: Int
    let maximumAggregateTagBytes: Int
    let maximumCandidates: Int
    let maximumMetadataCharacters: Int
    let maximumMetadataBytes: Int
    let maximumSnippetCharacters: Int
    let maximumSnippetBytes: Int
    let maximumResponseBytes: Int
    let maximumSourceTokensPerField: Int
    let maximumTokenComparisons: Int
    let maximumFuzzyComparisons: Int
    let maximumEditDistanceCells: Int
    let maximumQueuedRequests: Int
    let maximumStructuredValuesPerFile: Int

    /// Production limits keep memory, output, and typo correction bounded.
    static let `default` = SearchResourceLimits(
        maximumQueryBytes: SearchRequestLimits.maximumQueryBytes,
        maximumQueryTokens: 64,
        maximumTokenScalars: 64,
        maximumResults: SearchRequestLimits.maximumResults,
        maximumDirectoryEntries: 10_000,
        maximumFiles: 5_000,
        maximumAggregateBytes: 128 * 1024 * 1024,
        maximumSectionsPerFile: 2_000,
        maximumMarkdownLines: 50_000,
        maximumFrontMatterLines: 256,
        maximumTags: 128,
        maximumAggregateTagBytes: 16 * 1024,
        maximumCandidates: 1_000,
        maximumMetadataCharacters: 512,
        maximumMetadataBytes: 2_048,
        maximumSnippetCharacters: 320,
        maximumSnippetBytes: 1_024,
        maximumResponseBytes: 64 * 1024,
        maximumSourceTokensPerField: 50_000,
        maximumTokenComparisons: 2_000_000,
        maximumFuzzyComparisons: 250_000,
        maximumEditDistanceCells: 8_000_000,
        maximumQueuedRequests: 32,
        maximumStructuredValuesPerFile: 250_000
    )
}

/// Validates caller-controlled search shape before filesystem access.
enum SearchResourcePolicy {
    struct ValidatedRequest: Sendable {
        let request: VaultSearchRequest
        let fields: Set<SearchField>
        let formats: Set<FileFormat>
        let pathPrefix: String
        let queryTokens: [SearchToken]
    }

    static func validate(
        _ request: VaultSearchRequest,
        capabilities: SearchCapabilities,
        vaultPath: String,
        limits: SearchResourceLimits
    ) throws -> ValidatedRequest {
        guard !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VaultSearchRequestError.emptyQuery
        }
        guard request.query.utf8.count <= limits.maximumQueryBytes else {
            throw VaultSearchRequestError.queryTooLarge(limit: limits.maximumQueryBytes)
        }
        guard (1...limits.maximumResults).contains(request.limit) else {
            throw VaultSearchRequestError.invalidLimit(maximum: limits.maximumResults)
        }

        let queryTokens = SearchTokenizer.tokens(in: request.query)
        guard queryTokens.count <= limits.maximumQueryTokens else {
            throw VaultSearchRequestError.tooManyQueryTokens(limit: limits.maximumQueryTokens)
        }
        guard queryTokens.allSatisfy({
            $0.normalized.unicodeScalars.count <= limits.maximumTokenScalars
        }) else {
            throw VaultSearchRequestError.tokenTooLarge(limit: limits.maximumTokenScalars)
        }

        let fields: Set<SearchField>
        if let requested = request.fields {
            guard !requested.isEmpty else {
                throw VaultSearchRequestError.emptySelection("fields")
            }
            guard requested.count <= SearchField.allCases.count,
                  Set(requested).count == requested.count else {
                throw VaultSearchRequestError.invalidSelection("fields")
            }
            fields = Set(requested)
        } else {
            fields = Set(SearchField.allCases)
        }

        let supported = Set(capabilities.formats)
        let formats: Set<FileFormat>
        if let requested = request.formats {
            guard !requested.isEmpty else {
                throw VaultSearchRequestError.emptySelection("formats")
            }
            guard requested.count <= supported.count,
                  Set(requested).count == requested.count else {
                throw VaultSearchRequestError.invalidSelection("formats")
            }
            for format in requested where !supported.contains(format) {
                throw VaultSearchRequestError.unsupportedFormat(format)
            }
            formats = Set(requested)
        } else {
            formats = supported
        }

        let rawPrefix = request.pathPrefix ?? "notes/"
        guard rawPrefix.utf8.count <= SearchRequestLimits.maximumPathPrefixBytes,
              !rawPrefix.hasPrefix("/"),
              !rawPrefix.contains("\\"),
              !rawPrefix.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw VaultSearchRequestError.invalidPathPrefix
        }
        let components = rawPrefix
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        guard components.first == "notes",
              components.allSatisfy({ $0 != ".." && !$0.hasPrefix(".") }) else {
            throw VaultSearchRequestError.invalidPathPrefix
        }
        let prefix = components.joined(separator: "/") + "/"
        guard !PathValidator.containsSymbolicLinkComponent(
            relativePath: prefix,
            root: vaultPath
        ),
              !containsHiddenComponent(
                  relativeComponents: Array(components.dropFirst()),
                  vaultPath: vaultPath
              ),
              let resolved = try? PathValidator.resolve(
                  relativePath: prefix,
                  root: vaultPath
              ) else {
            throw VaultSearchRequestError.invalidPathPrefix
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            throw VaultSearchRequestError.invalidPathPrefix
        }

        return ValidatedRequest(
            request: request,
            fields: fields,
            formats: formats,
            pathPrefix: prefix,
            queryTokens: queryTokens
        )
    }

    private static func containsHiddenComponent(
        relativeComponents: [String],
        vaultPath: String
    ) -> Bool {
        var url = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent("notes", isDirectory: true)
        for component in relativeComponents {
            url.appendPathComponent(component, isDirectory: true)
            do {
                let values = try url.resourceValues(forKeys: [
                    .isHiddenKey, .isPackageKey,
                ])
                if values.isHidden == true || values.isPackage == true {
                    return true
                }
            } catch {
                // A nonexistent prefix is a valid, complete-empty scope. Other
                // access failures are handled conservatively during traversal.
                break
            }
        }
        return false
    }
}
