import MCP

/// Stable structured-result keys shared by file tool schemas and result mapping.
enum FileToolOutputField: String, Sendable {
    /// Canonical vault-relative path operated on.
    case path
    /// Original path for a completed move operation.
    case sourcePath = "source_path"
    /// Explicit destination alias for a completed move.
    case destinationPath = "destination_path"
    /// Structural vault area containing the path.
    case area
    /// Exact stored-byte revision when a file survives the operation.
    case revision
    /// Content-free format metadata for an explicit metadata read.
    case readMetadata = "metadata"
    /// Explicit byte-window metadata for a paginated text read.
    case textWindow = "text_window"
    /// First UTF-8 byte returned by a text window.
    case byteOffset = "byte_offset"
    /// Number of UTF-8 bytes returned by a text window.
    case byteCount = "byte_count"
    /// Complete validated document size in UTF-8 bytes.
    case totalBytes = "total_bytes"
    /// Offset accepted by the next continuation request.
    case nextByteOffset = "next_byte_offset"
}

extension Dictionary where Key == String, Value == MCP.Value {
    /// Accesses a structured-result object with a typed output key.
    subscript(field: FileToolOutputField) -> MCP.Value? {
        get { self[field.rawValue] }
        set { self[field.rawValue] = newValue }
    }
}
