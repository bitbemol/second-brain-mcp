import MCP

/// Stable structured-result keys shared by file tool schemas and result mapping.
enum FileToolOutputField: String, Sendable {
    /// Canonical vault-relative path operated on.
    case path
    /// Structural vault area containing the path.
    case area
    /// Exact stored-byte revision when a file survives the operation.
    case revision
    /// Caller-generated identity associated with a mutation result.
    case mutationID = "mutation_id"
    /// Whether a durable receipt supplied the completed result.
    case replayed
}

extension Dictionary where Key == String, Value == MCP.Value {
    /// Accesses a structured-result object with a typed output key.
    subscript(field: FileToolOutputField) -> MCP.Value? {
        get { self[field.rawValue] }
        set { self[field.rawValue] = newValue }
    }
}
