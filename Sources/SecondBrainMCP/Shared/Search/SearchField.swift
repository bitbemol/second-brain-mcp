/// Concrete file fields that can participate in a vault search.
enum SearchField: String, CaseIterable, Codable, Sendable {
    /// Front-matter title or a filename-derived fallback.
    case title
    /// Markdown section heading.
    case heading
    /// Markdown front-matter tags.
    case tags
    /// Vault-relative file path.
    case path
    /// File or section body content.
    case content
}
