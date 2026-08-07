/// Transport-neutral read boundary for ranked vault search.
protocol VaultSearchService: Sendable {
    /// Searches safe snapshots of supported notes without returning mutation revisions.
    ///
    /// - Parameter request: Validated or untrusted search input.
    /// - Returns: Ranked, bounded results and explicit coverage metadata.
    func search(_ request: VaultSearchRequest) async throws -> VaultSearchResponse
}
