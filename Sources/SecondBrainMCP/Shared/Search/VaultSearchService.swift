/// Transport-neutral boundary that locates atomic vault content.
protocol VaultSearchService: Sendable {
    /// Searches content but returns only coordinates consumable by `read_file`.
    func search(_ request: VaultSearchRequest) async throws -> VaultSearchResponse
}
