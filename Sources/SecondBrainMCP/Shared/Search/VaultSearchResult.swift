/// Why a known search file could not be evaluated completely.
enum VaultSearchResourceLimitReason: String, Codable, CaseIterable, Sendable {
    /// The individual file exceeded the search-specific byte ceiling.
    case fileBytes = "file_bytes"
    /// The request-wide corpus byte budget could not admit the file.
    case corpusBytes = "corpus_bytes"
    /// The candidate-count ceiling omitted the file.
    case fileCount = "file_count"
    /// Format-aware extraction omitted all or part of the searchable projection.
    case projection
    /// Relaxed lexical or fuzzy evaluation reached its fair work allowance.
    case matching
}

/// Whether a resource ceiling omitted a whole file or only part of its search surface.
enum VaultSearchResourceLimitImpact: String, Codable, CaseIterable, Sendable {
    case omitted
    case partial
}

/// One bounded, non-exhaustive resource-limit diagnostic.
struct VaultSearchResourceLimit: Codable, Equatable, Sendable {
    /// Canonical vault-relative path, validated by the sensitive-content policy.
    let path: String
    /// Stable machine-readable ceiling category.
    let reason: VaultSearchResourceLimitReason
    /// Whether the file was wholly omitted or only partially evaluated.
    let impact: VaultSearchResourceLimitImpact
}

/// One ranked matching passage from a searched file.
struct VaultSearchResult: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case path, format, title, heading, location, snippet, lineStart, lineEnd
        case matchedFields, relevance, termCoverage, completeQueryFields
        case area, physicalPage, printedPage, pdfPageKind, pdfTextExtractionStatus
    }

    /// Canonical vault-relative file path.
    let path: String
    /// Concrete stored file format.
    let format: FileFormat
    /// Structural vault area containing the result.
    let area: VaultArea
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
    /// Fields that contributed any evidence to this result.
    let matchedFields: [SearchField]
    /// Normalized ranking strength in `0...1`; this is not a probability.
    let relevance: Double
    /// Fraction of unique normalized query terms covered across all evidence.
    let termCoverage: Double
    /// Fields that individually satisfied the complete query.
    let completeQueryFields: [SearchField]
    /// One-based physical PDF page for page-content hits.
    let physicalPage: Int?
    /// Printed PDF page label when it differs from physical numbering.
    let printedPage: String?
    /// Coarse PDF page role used by ranking.
    let pdfPageKind: PDFSearchPageKind?
    /// PDF text availability; `nil` for non-PDF results.
    let pdfTextExtractionStatus: PDFTextExtractionStatus?

    /// Creates one result, retaining source compatibility for internal callers.
    init(
        path: String,
        format: FileFormat,
        area: VaultArea? = nil,
        title: String,
        heading: String?,
        location: VaultSearchLocation?,
        snippet: String,
        lineStart: Int,
        lineEnd: Int,
        matchedFields: [SearchField],
        relevance: Double = 0,
        termCoverage: Double = 0,
        completeQueryFields: [SearchField]? = nil,
        physicalPage: Int? = nil,
        printedPage: String? = nil,
        pdfPageKind: PDFSearchPageKind? = nil,
        pdfTextExtractionStatus: PDFTextExtractionStatus? = nil
    ) {
        self.path = path
        self.format = format
        self.area = area ?? (try? VaultArea.resolve(path: path)) ?? .notes
        self.title = title
        self.heading = heading
        self.location = location
        self.snippet = snippet
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.matchedFields = matchedFields
        self.relevance = relevance
        self.termCoverage = termCoverage
        self.completeQueryFields = completeQueryFields ?? []
        self.physicalPage = physicalPage
        self.printedPage = printedPage
        self.pdfPageKind = pdfPageKind
        self.pdfTextExtractionStatus = pdfTextExtractionStatus
    }

    /// Decodes older additive responses with conservative complete-match defaults.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let matched = try values.decode([SearchField].self, forKey: .matchedFields)
        self.init(
            path: try values.decode(String.self, forKey: .path),
            format: try values.decode(FileFormat.self, forKey: .format),
            area: try values.decodeIfPresent(VaultArea.self, forKey: .area),
            title: try values.decode(String.self, forKey: .title),
            heading: try values.decodeIfPresent(String.self, forKey: .heading),
            location: try values.decodeIfPresent(VaultSearchLocation.self, forKey: .location),
            snippet: try values.decode(String.self, forKey: .snippet),
            lineStart: try values.decode(Int.self, forKey: .lineStart),
            lineEnd: try values.decode(Int.self, forKey: .lineEnd),
            matchedFields: matched,
            relevance: try values.decodeIfPresent(Double.self, forKey: .relevance) ?? 0,
            termCoverage: try values.decodeIfPresent(Double.self, forKey: .termCoverage) ?? 0,
            completeQueryFields: try values.decodeIfPresent(
                [SearchField].self,
                forKey: .completeQueryFields
            ) ?? [],
            physicalPage: try values.decodeIfPresent(Int.self, forKey: .physicalPage),
            printedPage: try values.decodeIfPresent(String.self, forKey: .printedPage),
            pdfPageKind: try values.decodeIfPresent(
                PDFSearchPageKind.self,
                forKey: .pdfPageKind
            ),
            pdfTextExtractionStatus: try values.decodeIfPresent(
                PDFTextExtractionStatus.self,
                forKey: .pdfTextExtractionStatus
            )
        )
    }
}

/// Bounded search results plus coverage facts for the caller.
struct VaultSearchResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case strategy, minimumRelevance, results, searchedFileCount, skippedFileCount
        case skippedSensitiveFileCount, resourceLimitedFileCount, resourceLimitSamples
        case moreResultsAvailable, nextCursor, omittedResultCountLowerBound
        case coverageIncomplete, truncated, pdfSummary
    }

    /// Effective matching strategy.
    let strategy: SearchStrategy
    /// Effective normalized relevance floor.
    let minimumRelevance: Double
    /// Ranked passages in stable order for the examined current corpus.
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
    /// Stable bounded examples explaining known resource omissions.
    let resourceLimitSamples: [VaultSearchResourceLimit]
    /// Whether known matching results were omitted from the returned page.
    let moreResultsAvailable: Bool
    /// Opaque continuation token for the next stable page, when available.
    let nextCursor: String?
    /// Minimum number of ranked results known to be omitted after this page.
    let omittedResultCountLowerBound: Int
    /// Aggregate PDF extraction facts, including references with no matching page.
    let pdfSummary: VaultSearchPDFSummary
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
        coverageIncomplete: Bool,
        minimumRelevance: Double = SearchRequestLimits.defaultMinimumRelevance,
        resourceLimitSamples: [VaultSearchResourceLimit] = [],
        nextCursor: String? = nil,
        omittedResultCountLowerBound: Int = 0,
        pdfSummary: VaultSearchPDFSummary = .empty
    ) {
        self.strategy = strategy
        self.minimumRelevance = minimumRelevance
        self.results = results
        self.searchedFileCount = searchedFileCount
        self.skippedFileCount = skippedFileCount
        self.skippedSensitiveFileCount = skippedSensitiveFileCount
        self.resourceLimitedFileCount = resourceLimitedFileCount
        self.resourceLimitSamples = resourceLimitSamples
        self.moreResultsAvailable = moreResultsAvailable
        self.nextCursor = nextCursor
        self.omittedResultCountLowerBound = omittedResultCountLowerBound
        self.pdfSummary = pdfSummary
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
            moreResultsAvailable: try values.decode(Bool.self, forKey: .moreResultsAvailable),
            coverageIncomplete: try values.decode(Bool.self, forKey: .coverageIncomplete),
            minimumRelevance: try values.decodeIfPresent(
                Double.self,
                forKey: .minimumRelevance
            ) ?? SearchRequestLimits.defaultMinimumRelevance,
            resourceLimitSamples: try values.decodeIfPresent(
                [VaultSearchResourceLimit].self,
                forKey: .resourceLimitSamples
            ) ?? [],
            nextCursor: try values.decodeIfPresent(String.self, forKey: .nextCursor),
            omittedResultCountLowerBound: try values.decodeIfPresent(
                Int.self,
                forKey: .omittedResultCountLowerBound
            ) ?? 0,
            pdfSummary: try values.decodeIfPresent(
                VaultSearchPDFSummary.self,
                forKey: .pdfSummary
            ) ?? .empty
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
        try values.encode(minimumRelevance, forKey: .minimumRelevance)
        try values.encode(results, forKey: .results)
        try values.encode(searchedFileCount, forKey: .searchedFileCount)
        try values.encode(skippedFileCount, forKey: .skippedFileCount)
        try values.encode(skippedSensitiveFileCount, forKey: .skippedSensitiveFileCount)
        try values.encode(resourceLimitedFileCount, forKey: .resourceLimitedFileCount)
        try values.encode(resourceLimitSamples, forKey: .resourceLimitSamples)
        try values.encode(moreResultsAvailable, forKey: .moreResultsAvailable)
        try values.encodeIfPresent(nextCursor, forKey: .nextCursor)
        try values.encode(
            omittedResultCountLowerBound,
            forKey: .omittedResultCountLowerBound
        )
        try values.encode(pdfSummary, forKey: .pdfSummary)
        try values.encode(coverageIncomplete, forKey: .coverageIncomplete)
        try values.encode(truncated, forKey: .truncated)
    }
}
