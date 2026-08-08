/// Transport-neutral input for one bounded note search.
struct VaultSearchRequest: Sendable {
    /// Caller text interpreted according to ``strategy``.
    let query: String
    /// Explicit matching behavior. Defaults to ``SearchStrategy/smart``.
    let strategy: SearchStrategy
    /// Optional concrete field selection; `nil` means every field.
    let fields: [SearchField]?
    /// Optional concrete format selection; `nil` means every searchable format.
    let formats: [FileFormat]?
    /// Optional notes-relative directory prefix used to narrow traversal.
    let pathPrefix: String?
    /// Maximum number of different files returned.
    let limit: Int
    /// Minimum normalized relevance accepted into the result set.
    let minimumRelevance: Double

    /// Creates a search request with safe, useful defaults.
    init(
        query: String,
        strategy: SearchStrategy = .smart,
        fields: [SearchField]? = nil,
        formats: [FileFormat]? = nil,
        pathPrefix: String? = nil,
        limit: Int = SearchRequestLimits.defaultResults,
        minimumRelevance: Double = SearchRequestLimits.defaultMinimumRelevance
    ) {
        self.query = query
        self.strategy = strategy
        self.fields = fields
        self.formats = formats
        self.pathPrefix = pathPrefix
        self.limit = limit
        self.minimumRelevance = minimumRelevance
    }
}
