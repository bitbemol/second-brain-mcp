/// Read coordinates for one atomic element whose content matched a search.
struct VaultSearchResult: Codable, Equatable, Sendable {
    /// Canonical vault-relative path accepted by `read_file`.
    let path: String
    /// Existing global storage format accepted by `read_file`.
    let format: FileFormat
    /// One-based physical PDF page; absent for whole-file atoms.
    let page: Int?

    init(path: String, format: FileFormat, page: Int? = nil) {
        self.path = path
        self.format = format
        self.page = page
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
