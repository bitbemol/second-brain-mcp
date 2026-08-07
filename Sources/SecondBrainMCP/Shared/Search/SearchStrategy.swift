/// Matching behavior supported by the vault search boundary.
enum SearchStrategy: String, CaseIterable, Codable, Sendable {
    /// Balanced ranking that prefers literal and lexical matches, then applies
    /// conservative typo tolerance to otherwise unmatched terms.
    case smart
    /// Case- and diacritic-insensitive literal substring matching. Punctuation
    /// remains significant, making this suitable for identifiers and paths.
    case exact
    /// Ordered adjacent-term matching across punctuation and whitespace.
    case phrase
    /// Word-oriented matching ranked by coverage and field importance.
    case lexical
    /// Conservative edit-distance matching for words of at least three characters.
    case fuzzy
}
