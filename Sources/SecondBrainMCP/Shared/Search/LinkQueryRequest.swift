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

/// Projection of backlinks before pagination.
enum LinkQueryGrouping: String, CaseIterable, Codable, Sendable {
    case source
    case occurrence
}

/// Read-only request for resolving or traversing Obsidian wiki links.
struct LinkQueryRequest: Sendable {
    let direction: LinkQueryDirection
    let target: String
    let fromPath: String?
    let groupBy: LinkQueryGrouping?
    let sourcePath: String?
    let limit: Int
    let cursor: String?

    init(
        direction: LinkQueryDirection,
        target: String,
        fromPath: String? = nil,
        groupBy: LinkQueryGrouping? = nil,
        sourcePath: String? = nil,
        limit: Int = LinkQueryLimits.defaultResults,
        cursor: String? = nil
    ) {
        self.direction = direction
        self.target = target
        self.fromPath = fromPath
        self.groupBy = groupBy
        self.sourcePath = sourcePath
        self.limit = limit
        self.cursor = cursor
    }
}
