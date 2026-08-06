/// Stable argument names used by the compact MCP file tools.
///
/// Schema generation and request decoding share these keys so the advertised
/// wire contract cannot drift from the values the frontend actually consumes.
enum FileToolArgument: String, Sendable {
    /// Declared concrete file format.
    case format
    /// Vault-relative source or destination path.
    case path
    /// Inline text content for create and update operations.
    case content
    /// External media source path.
    case source
    /// Markdown tags supplied during creation.
    case tags
    /// Explicit create-time media transformation.
    case transform
    /// Whether a specialized read should include raw content.
    case raw
    /// Number of trailing log lines to return.
    case tailLines = "tail_lines"
    /// First log line in a bounded range.
    case startLine = "start_line"
    /// Maximum log lines returned from a range.
    case maxLines = "max_lines"
    /// Physical PDF page number.
    case page
    /// Printed PDF page label.
    case bookPage = "book_page"
    /// Inclusive physical PDF page range.
    case pageRange = "page_range"
    /// PDF text query.
    case query
    /// Maximum PDF pages returned.
    case maxPages = "max_pages"
    /// Format-specific update strategy.
    case mode
    /// Exact text substitutions for patch updates.
    case replacements
    /// Original text in one exact substitution.
    case oldText = "old_text"
    /// Replacement text in one exact substitution.
    case newText = "new_text"
}

extension Dictionary where Key == String {
    /// Accesses a string-keyed dictionary with a typed file-tool argument.
    subscript(argument: FileToolArgument) -> Value? {
        get { self[argument.rawValue] }
        set { self[argument.rawValue] = newValue }
    }
}
