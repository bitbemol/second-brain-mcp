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

/// One bounded page of locators. Absence of `nextCursor` means search is complete.
struct VaultSearchResponse: Codable, Equatable, Sendable {
    let results: [VaultSearchResult]
    let nextCursor: String?

    let coverage: DiscoveryCoverage

    init(results: [VaultSearchResult], nextCursor: String? = nil,
         coverage: DiscoveryCoverage = .full) {
        self.results = results
        self.nextCursor = nextCursor
        self.coverage = coverage
    }
}
