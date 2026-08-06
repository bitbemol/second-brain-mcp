/// Format-specific strategies accepted by `update_file`.
enum FileUpdateMode: String, Codable, Sendable {
    /// Replace the complete stored representation.
    case replace
    /// Append content without replacing existing bytes.
    case append
    /// Apply exact text replacements.
    case patch
}
