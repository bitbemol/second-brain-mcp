/// Transport-neutral input for one bounded vault search.
struct VaultSearchRequest: Sendable {
    /// Caller text interpreted according to ``strategy``.
    let query: String
    /// Explicit matching behavior. Defaults to ``SearchStrategy/smart``.
    let strategy: SearchStrategy
    /// Optional concrete field selection; `nil` means every field.
    let fields: [SearchField]?
    /// Optional concrete format selection; `nil` means every searchable format.
    let formats: [FileFormat]?
    /// Optional structural-area selection; `nil` means every searchable area.
    let areas: [VaultArea]?
    /// Optional vault-relative directory prefix used to narrow traversal.
    let pathPrefix: String?
    /// Maximum number of ranked passages returned in one page.
    let limit: Int
    /// Minimum normalized relevance accepted into the result set.
    let minimumRelevance: Double
    /// Maximum independently relevant passages retained from one file.
    let maxHitsPerFile: Int
    /// Opaque continuation token returned by a preceding identical search.
    let cursor: String?

    /// Creates a search request with safe, useful defaults.
    init(
        query: String,
        strategy: SearchStrategy = .smart,
        fields: [SearchField]? = nil,
        formats: [FileFormat]? = nil,
        areas: [VaultArea]? = nil,
        pathPrefix: String? = nil,
        limit: Int = SearchRequestLimits.defaultResults,
        minimumRelevance: Double = SearchRequestLimits.defaultMinimumRelevance,
        maxHitsPerFile: Int = 1,
        cursor: String? = nil
    ) {
        self.query = query
        self.strategy = strategy
        self.fields = fields
        self.formats = formats
        self.areas = areas
        self.pathPrefix = pathPrefix
        self.limit = limit
        self.minimumRelevance = minimumRelevance
        self.maxHitsPerFile = maxHitsPerFile
        self.cursor = cursor
    }
}
