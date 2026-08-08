import Foundation

/// Deterministic ceilings for one live search request.
struct SearchResourceLimits: Sendable {
    let maximumQueryBytes: Int
    let maximumQueryTokens: Int
    let maximumTokenScalars: Int
    let maximumResults: Int
    let maximumDirectoryEntries: Int
    let maximumFiles: Int
    let maximumFileBytes: Int
    let maximumPDFFileBytes: Int
    let maximumAggregateBytes: Int
    let maximumAggregateProjectionBytes: Int
    let maximumAggregateSections: Int
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
    let maximumLiteralOccurrencesPerField: Int
    let maximumLiteralOccurrencesPerRequest: Int
    let maximumTokenComparisons: Int
    let maximumFuzzyComparisons: Int
    let maximumEditDistanceCells: Int
    let maximumQueuedRequests: Int
    let maximumStructuredValuesPerFile: Int
    let maximumPDFPagesPerFile: Int
    let maximumPDFTextBytesPerFile: Int

    /// Production limits keep memory, output, and typo correction bounded.
    static let `default` = SearchResourceLimits(
        maximumQueryBytes: SearchRequestLimits.maximumQueryBytes,
        maximumQueryTokens: 64,
        maximumTokenScalars: 64,
        maximumResults: SearchRequestLimits.maximumResults,
        maximumDirectoryEntries: 10_000,
        maximumFiles: 5_000,
        maximumFileBytes: 8 * 1024 * 1024,
        maximumPDFFileBytes: 64 * 1024 * 1024,
        maximumAggregateBytes: 128 * 1024 * 1024,
        maximumAggregateProjectionBytes: 64 * 1024 * 1024,
        maximumAggregateSections: 100_000,
        maximumSectionsPerFile: 2_000,
        maximumMarkdownLines: 50_000,
        maximumFrontMatterLines: 256,
        maximumTags: 128,
        maximumAggregateTagBytes: 16 * 1024,
        maximumCandidates: 10_000,
        maximumMetadataCharacters: 512,
        maximumMetadataBytes: 2_048,
        maximumSnippetCharacters: 320,
        maximumSnippetBytes: 1_024,
        maximumResponseBytes: 64 * 1024,
        maximumSourceTokensPerField: 50_000,
        maximumLiteralOccurrencesPerField: 100_000,
        maximumLiteralOccurrencesPerRequest: 1_000_000,
        maximumTokenComparisons: 2_000_000,
        maximumFuzzyComparisons: 250_000,
        maximumEditDistanceCells: 8_000_000,
        maximumQueuedRequests: 32,
        maximumStructuredValuesPerFile: 250_000,
        maximumPDFPagesPerFile: 2_000,
        maximumPDFTextBytesPerFile: 8 * 1024 * 1024
    )
}

/// Validates caller-controlled search shape before filesystem access.
enum SearchResourcePolicy {
    struct ValidatedRequest: Sendable {
        let request: VaultSearchRequest
        let fields: Set<SearchField>
        let formats: Set<FileFormat>
        let areas: Set<VaultArea>
        let scopePrefixes: [String]
        let queryTokens: [SearchToken]
        let cursorOffset: Int
        let expectedCorpusFingerprint: String?
        let cursorFingerprint: String
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
        guard request.minimumRelevance.isFinite,
              (0...1).contains(request.minimumRelevance) else {
            throw VaultSearchRequestError.invalidMinimumRelevance
        }
        guard (1...SearchRequestLimits.maximumHitsPerFile)
            .contains(request.maxHitsPerFile) else {
            throw VaultSearchRequestError.invalidMaxHitsPerFile(
                maximum: SearchRequestLimits.maximumHitsPerFile
            )
        }

        let allQueryTokens = SearchTokenizer.tokens(in: request.query)
        guard allQueryTokens.count <= limits.maximumQueryTokens else {
            throw VaultSearchRequestError.tooManyQueryTokens(limit: limits.maximumQueryTokens)
        }
        guard allQueryTokens.allSatisfy({
            $0.normalized.unicodeScalars.count <= limits.maximumTokenScalars
        }) else {
            throw VaultSearchRequestError.tokenTooLarge(limit: limits.maximumTokenScalars)
        }
        let queryTokens = request.strategy == .smart
            ? SearchQueryAnalyzer.significantTokens(in: request.query)
            : allQueryTokens

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
        let explicitlyRequestedFormats: Set<FileFormat>?
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
            explicitlyRequestedFormats = Set(requested)
        } else {
            explicitlyRequestedFormats = nil
        }

        let areas: Set<VaultArea>
        if let requested = request.areas {
            guard !requested.isEmpty else {
                throw VaultSearchRequestError.emptySelection("areas")
            }
            guard requested.count <= capabilities.areas.count,
                  Set(requested).count == requested.count,
                  requested.allSatisfy(capabilities.areas.contains) else {
                throw VaultSearchRequestError.invalidSelection("areas")
            }
            areas = Set(requested)
        } else if let rawPrefix = request.pathPrefix,
                  let areaName = rawPrefix.split(
                      separator: "/",
                      omittingEmptySubsequences: true
                  ).first,
                  let inferred = VaultArea(rawValue: String(areaName)),
                  capabilities.areas.contains(inferred) {
            areas = [inferred]
        } else if let explicitlyRequestedFormats {
            areas = Set(capabilities.areas.filter { area in
                explicitlyRequestedFormats.contains(where: {
                    capabilities.supports($0, in: area)
                })
            })
        } else {
            // Keep ordinary note discovery fast. References remain available
            // through an explicit area, a PDF format, or references/ prefix.
            areas = capabilities.areas.contains(.notes) ? [.notes] : []
        }
        guard !areas.isEmpty else {
            throw VaultSearchRequestError.invalidSelection("areas")
        }

        let formats: Set<FileFormat>
        if let explicitlyRequestedFormats {
            formats = explicitlyRequestedFormats
        } else {
            formats = areas.reduce(into: Set<FileFormat>()) { result, area in
                result.formUnion(capabilities.formats(in: area))
            }
        }

        let scopePrefixes: [String]
        if let rawPrefix = request.pathPrefix {
            let prefix = try canonicalPrefix(
                rawPrefix,
                allowedAreas: areas,
                vaultPath: vaultPath
            )
            let areaName = String(prefix.prefix { $0 != "/" })
            guard let area = VaultArea(rawValue: areaName),
                  formats.contains(where: {
                      capabilities.supports($0, in: area)
                  }) else {
                throw VaultSearchRequestError.invalidSelection(
                    "formats and path_prefix"
                )
            }
            scopePrefixes = [prefix]
        } else {
            scopePrefixes = capabilities.areas
                .filter(areas.contains)
                .map { $0.rawValue + "/" }
        }

        guard formats.allSatisfy({ format in
            areas.contains(where: { capabilities.supports(format, in: $0) })
        }) else {
            throw VaultSearchRequestError.invalidSelection("formats and areas")
        }

        let fingerprint = SearchCursorCodec.fingerprint(
            request: request,
            fields: fields,
            formats: formats,
            areas: areas,
            scopePrefixes: scopePrefixes
        )
        let decodedCursor = try request.cursor.map {
            try SearchCursorCodec.decode($0, fingerprint: fingerprint)
        }
        let cursorOffset = decodedCursor?.offset ?? 0
        guard cursorOffset <= limits.maximumCandidates else {
            throw VaultSearchRequestError.invalidCursor
        }

        return ValidatedRequest(
            request: request,
            fields: fields,
            formats: formats,
            areas: areas,
            scopePrefixes: scopePrefixes,
            queryTokens: queryTokens,
            cursorOffset: cursorOffset,
            expectedCorpusFingerprint: decodedCursor?.corpusFingerprint,
            cursorFingerprint: fingerprint
        )
    }

    private static func canonicalPrefix(
        _ rawPrefix: String,
        allowedAreas: Set<VaultArea>,
        vaultPath: String
    ) throws -> String {
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
        guard let first = components.first,
              let area = VaultArea(rawValue: first),
              allowedAreas.contains(area),
              components.allSatisfy({ $0 != ".." && !$0.hasPrefix(".") }) else {
            throw VaultSearchRequestError.invalidPathPrefix
        }
        let prefix = components.joined(separator: "/") + "/"
        guard !PathValidator.containsSymbolicLinkComponent(
            relativePath: prefix,
            root: vaultPath
        ),
              !containsHiddenComponent(
                  area: area,
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
        return prefix
    }

    private static func containsHiddenComponent(
        area: VaultArea,
        relativeComponents: [String],
        vaultPath: String
    ) -> Bool {
        var url = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent(area.rawValue, isDirectory: true)
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
