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

/// Supported semantic directions for the compact vault-link query.
enum LinkQueryDirection: String, CaseIterable, Codable, Sendable {
    case resolve
    case outgoing
    case backlinks
}

/// Kind of Obsidian wiki-link syntax observed in Markdown.
enum VaultWikiLinkKind: String, Codable, Sendable {
    case link
    case embed
}

/// Read-only request for resolving or traversing Obsidian wiki links.
struct LinkQueryRequest: Sendable {
    let direction: LinkQueryDirection
    let target: String
    let fromPath: String?
    let limit: Int
    let cursor: String?

    init(
        direction: LinkQueryDirection,
        target: String,
        fromPath: String? = nil,
        limit: Int = LinkQueryLimits.defaultResults,
        cursor: String? = nil
    ) {
        self.direction = direction
        self.target = target
        self.fromPath = fromPath
        self.limit = limit
        self.cursor = cursor
    }
}
