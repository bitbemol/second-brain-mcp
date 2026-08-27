/// Read coordinates for one atomic element whose content matched a search.
struct VaultSearchResult: Codable, Equatable, Sendable {
    /// Canonical vault-relative path accepted by `read_file`.
    let path: String
    /// Existing global storage format accepted by `read_file`.
    let format: FileFormat
    /// One-based physical PDF page; absent for whole-file atoms.
    let page: Int?
    /// Stable JSON Canvas node identifier; absent outside Canvas node atoms.
    let canvasNodeID: String?
    /// Exact JSON Canvas field containing the match; absent outside Canvas node atoms.
    let canvasField: String?

    private enum CodingKeys: String, CodingKey {
        case path
        case format
        case page
        case canvasNodeID = "canvas_node_id"
        case canvasField = "canvas_field"
    }

    init(
        path: String,
        format: FileFormat,
        page: Int? = nil,
        canvasNodeID: String? = nil,
        canvasField: String? = nil
    ) {
        self.path = path
        self.format = format
        self.page = page
        self.canvasNodeID = canvasNodeID
        self.canvasField = canvasField
    }
}

/// One structured link-resolution result without note content or snippets.
struct LinkQueryResult: Codable, Equatable, Sendable {
    let sourcePath: String?
    let target: String
    let resolvedPath: String?
    let kind: VaultWikiLinkKind
    let alias: String?
    let occurrence: Int?
    let ambiguous: Bool
}

/// Bounded response for one link-query page.
struct LinkQueryResponse: Codable, Equatable, Sendable {
    let direction: LinkQueryDirection
    let results: [LinkQueryResult]
    let nextCursor: String?

    init(
        direction: LinkQueryDirection,
        results: [LinkQueryResult],
        nextCursor: String? = nil
    ) {
        self.direction = direction
        self.results = results
        self.nextCursor = nextCursor
    }
}

/// One bounded page of locators. Absence of `nextCursor` means search is complete.
struct VaultSearchResponse: Codable, Equatable, Sendable {
    let results: [VaultSearchResult]
    let nextCursor: String?

    init(results: [VaultSearchResult], nextCursor: String? = nil) {
        self.results = results
        self.nextCursor = nextCursor
    }
}
