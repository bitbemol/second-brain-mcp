/// One best matching section from a searched note.
struct VaultSearchResult: Codable, Equatable, Sendable {
    /// Canonical vault-relative note path.
    let path: String
    /// Concrete stored file format.
    let format: FileFormat
    /// Human-readable title derived from trusted file structure.
    let title: String
    /// Markdown section heading, when the hit belongs to one.
    let heading: String?
    /// Structured format coordinates, when line ranges cannot identify the hit.
    let location: VaultSearchLocation?
    /// Bounded, untrusted excerpt from vault content.
    let snippet: String
    /// One-based first source line represented by the matching section.
    let lineStart: Int
    /// One-based last source line represented by the matching section.
    let lineEnd: Int
    /// Concrete fields that contributed to this result's rank.
    let matchedFields: [SearchField]
}

/// Bounded search results plus coverage facts for the caller.
struct VaultSearchResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case strategy, results, searchedFileCount, skippedFileCount
        case skippedSensitiveFileCount, resourceLimitedFileCount
        case moreResultsAvailable, coverageIncomplete, truncated
    }

    /// Effective matching strategy.
    let strategy: SearchStrategy
    /// At most one best result per file, in stable rank order for the examined corpus.
    let results: [VaultSearchResult]
    /// Number of safe, eligible files whose content was searched.
    let searchedFileCount: Int
    /// Number of eligible files skipped because they could not be read safely.
    let skippedFileCount: Int
    /// Number of files omitted by the sensitive-content boundary.
    let skippedSensitiveFileCount: Int
    /// Known files wholly or partially omitted by search resource ceilings.
    ///
    /// When directory traversal itself is cut short, this remains a lower bound
    /// because undiscovered entries cannot be counted safely.
    let resourceLimitedFileCount: Int
    /// Whether known matching results were omitted from the returned page.
    let moreResultsAvailable: Bool
    /// Whether any in-scope content could not be fully evaluated.
    let coverageIncomplete: Bool
    /// Backward-compatible union of result and coverage truncation.
    let truncated: Bool

    /// Creates one response while keeping legacy `truncated` semantics derived.
    init(
        strategy: SearchStrategy,
        results: [VaultSearchResult],
        searchedFileCount: Int,
        skippedFileCount: Int,
        skippedSensitiveFileCount: Int,
        resourceLimitedFileCount: Int,
        moreResultsAvailable: Bool,
        coverageIncomplete: Bool
    ) {
        self.strategy = strategy
        self.results = results
        self.searchedFileCount = searchedFileCount
        self.skippedFileCount = skippedFileCount
        self.skippedSensitiveFileCount = skippedSensitiveFileCount
        self.resourceLimitedFileCount = resourceLimitedFileCount
        self.moreResultsAvailable = moreResultsAvailable
        self.coverageIncomplete = coverageIncomplete
        self.truncated = moreResultsAvailable || coverageIncomplete
    }

    /// Decodes only responses whose legacy union agrees with its source facts.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let encodedTruncated = try values.decode(Bool.self, forKey: .truncated)
        self.init(
            strategy: try values.decode(SearchStrategy.self, forKey: .strategy),
            results: try values.decode([VaultSearchResult].self, forKey: .results),
            searchedFileCount: try values.decode(Int.self, forKey: .searchedFileCount),
            skippedFileCount: try values.decode(Int.self, forKey: .skippedFileCount),
            skippedSensitiveFileCount: try values.decode(
                Int.self,
                forKey: .skippedSensitiveFileCount
            ),
            resourceLimitedFileCount: try values.decode(
                Int.self,
                forKey: .resourceLimitedFileCount
            ),
            moreResultsAvailable: try values.decode(
                Bool.self,
                forKey: .moreResultsAvailable
            ),
            coverageIncomplete: try values.decode(
                Bool.self,
                forKey: .coverageIncomplete
            )
        )
        guard encodedTruncated == truncated else {
            throw DecodingError.dataCorruptedError(
                forKey: .truncated,
                in: values,
                debugDescription: "truncated must equal moreResultsAvailable OR coverageIncomplete"
            )
        }
    }

    /// Encodes the response including its derived compatibility field.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(strategy, forKey: .strategy)
        try values.encode(results, forKey: .results)
        try values.encode(searchedFileCount, forKey: .searchedFileCount)
        try values.encode(skippedFileCount, forKey: .skippedFileCount)
        try values.encode(skippedSensitiveFileCount, forKey: .skippedSensitiveFileCount)
        try values.encode(resourceLimitedFileCount, forKey: .resourceLimitedFileCount)
        try values.encode(moreResultsAvailable, forKey: .moreResultsAvailable)
        try values.encode(coverageIncomplete, forKey: .coverageIncomplete)
        try values.encode(truncated, forKey: .truncated)
    }
}
