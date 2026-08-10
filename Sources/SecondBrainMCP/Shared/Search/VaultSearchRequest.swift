/// Transport-neutral input for locating atomic vault content.
struct VaultSearchRequest: Sendable {
    /// Structural vault area searched by this request.
    let location: VaultArea
    /// Optional text that every matching atom must contain.
    let query: String?
    /// Exact normalized Markdown tags that notes must contain.
    let tags: [String]
    /// Inclusive lower bound for the Markdown `created` date.
    let createdFrom: String?
    /// Inclusive upper bound for the Markdown `created` date.
    let createdThrough: String?
    /// Maximum locators returned in this response page.
    let limit: Int
    /// Opaque continuation token from an identical preceding request.
    let cursor: String?

    init(
        location: VaultArea,
        query: String? = nil,
        tags: [String] = [],
        createdFrom: String? = nil,
        createdThrough: String? = nil,
        limit: Int = SearchRequestLimits.defaultResults,
        cursor: String? = nil
    ) {
        self.location = location
        self.query = query
        self.tags = tags
        self.createdFrom = createdFrom
        self.createdThrough = createdThrough
        self.limit = limit
        self.cursor = cursor
    }
}
