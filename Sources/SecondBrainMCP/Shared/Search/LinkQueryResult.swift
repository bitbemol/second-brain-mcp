/// One occurrence or one source/target group, without note content.
struct LinkQueryResult: Codable, Equatable, Sendable {
    let sourcePath: String?
    let target: String?
    let resolvedPath: String?
    let resolvedFormat: FileFormat?
    let kind: VaultWikiLinkKind?
    let alias: String?
    let fragment: String?
    let occurrence: Int?
    let occurrenceCount: Int?
    let ambiguous: Bool

    /// Constructs an occurrence or a resolve-only candidate.
    init(
        sourcePath: String?,
        target: String,
        resolvedPath: String?,
        kind: VaultWikiLinkKind,
        alias: String?,
        occurrence: Int?,
        ambiguous: Bool,
        resolvedFormat: FileFormat? = nil,
        fragment: String? = nil
    ) {
        self.sourcePath = sourcePath
        self.target = target
        self.resolvedPath = resolvedPath
        self.resolvedFormat = resolvedFormat
        self.kind = kind
        self.alias = alias
        self.fragment = fragment
        self.occurrence = occurrence
        self.occurrenceCount = nil
        self.ambiguous = ambiguous
    }

    /// Constructs a group without inventing a representative occurrence.
    init(
        sourcePath: String,
        resolvedPath: String,
        resolvedFormat: FileFormat,
        occurrenceCount: Int,
        ambiguous: Bool
    ) {
        self.sourcePath = sourcePath
        self.target = nil
        self.resolvedPath = resolvedPath
        self.resolvedFormat = resolvedFormat
        self.kind = nil
        self.alias = nil
        self.fragment = nil
        self.occurrence = nil
        self.occurrenceCount = occurrenceCount
        self.ambiguous = ambiguous
    }
}

/// Bounded response for one link-query page.
struct LinkQueryResponse: Codable, Equatable, Sendable {
    let direction: LinkQueryDirection
    let results: [LinkQueryResult]
    let nextCursor: String?
    let coverage: DiscoveryCoverage

    init(
        direction: LinkQueryDirection,
        results: [LinkQueryResult],
        nextCursor: String? = nil,
        coverage: DiscoveryCoverage = .full
    ) {
        self.direction = direction
        self.results = results
        self.nextCursor = nextCursor
        self.coverage = coverage
    }
}
