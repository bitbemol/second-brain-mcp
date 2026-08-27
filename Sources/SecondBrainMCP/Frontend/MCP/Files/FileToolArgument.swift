/// Stable argument names used by the compact MCP file tools.
///
/// Schema generation and request decoding share these keys so the advertised
/// wire contract cannot drift from the values the frontend actually consumes.
enum FileToolArgument: String, Sendable {
    /// Declared concrete file format.
    case format
    /// Vault-relative source or destination path.
    case path
    /// Exact-byte revision that an update or delete expects to replace.
    case expectedRevision = "expected_revision"
    /// Inline text content for create and update operations.
    case content
    /// External media source path.
    case source
    /// Markdown tags supplied during creation.
    case tags
    /// Explicit create-time media transformation.
    case transform
    /// Agent-facing content or metadata representation.
    case view
    /// Number of trailing log lines to return.
    case tailLines = "tail_lines"
    /// First log line in a bounded range.
    case startLine = "start_line"
    /// Maximum log lines returned from a range.
    case maxLines = "max_lines"
    /// One physical PDF page number.
    case page
    /// Ordered physical PDF page numbers.
    case pages
    /// Inclusive physical PDF page range.
    case pageRange = "page_range"
    /// Zero-based UTF-8 byte offset for text pagination.
    case byteOffset = "byte_offset"
    /// Maximum UTF-8 bytes returned for one text chunk.
    case maxBytes = "max_bytes"
    /// Exact Canvas node identifier returned by search.
    case canvasNodeID = "canvas_node_id"
    /// Semantic Canvas field whose decoded UTF-8 value should be read.
    case canvasField = "canvas_field"
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
