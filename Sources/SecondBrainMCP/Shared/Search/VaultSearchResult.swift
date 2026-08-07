/// One best matching section from a searched note.
struct VaultSearchResult: Codable, Equatable, Sendable {
    /// Canonical vault-relative note path.
    let path: String
    /// Concrete stored file format.
    let format: FileFormat
    /// Human-readable title derived from trusted file structure.
    let title: String
    /// Markdown section heading, when the hit belongs to one.
    let heading: String?
    /// Structured format coordinates, when line ranges cannot identify the hit.
    let location: VaultSearchLocation?
    /// Bounded, untrusted excerpt from vault content.
    let snippet: String
    /// One-based first source line represented by the matching section.
    let lineStart: Int
    /// One-based last source line represented by the matching section.
    let lineEnd: Int
    /// Concrete fields that contributed to this result's rank.
    let matchedFields: [SearchField]
}

/// Bounded search results plus coverage facts for the caller.
struct VaultSearchResponse: Codable, Equatable, Sendable {
    /// Effective matching strategy.
    let strategy: SearchStrategy
    /// At most one best result per file, in stable rank order for the examined corpus.
    let results: [VaultSearchResult]
    /// Number of safe, eligible files whose content was searched.
    let searchedFileCount: Int
    /// Number of eligible files skipped because they could not be read safely.
    let skippedFileCount: Int
    /// Number of files omitted by the sensitive-content boundary.
    let skippedSensitiveFileCount: Int
    /// Whether traversal, work, candidate, or result limits omitted possible hits.
    let truncated: Bool
}
