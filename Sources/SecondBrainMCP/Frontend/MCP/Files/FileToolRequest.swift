/// Stable names understood by the compact MCP file boundary.
enum FileToolName: String, CaseIterable, Sendable {
    /// Create a concrete file.
    case create = "create_file"
    /// Read a concrete file.
    case read = "read_file"
    /// Update a concrete file.
    case update = "update_file"
    /// Soft-delete a concrete file.
    case delete = "delete_file"

    /// Transport-neutral CRUD operation represented by the tool.
    var operation: FileCRUDOperation {
        switch self {
        case .create: .create
        case .read: .read
        case .update: .update
        case .delete: .delete
        }
    }
}

/// Decoded request accepted by the file-service executor.
enum FileToolRequest: Sendable {
    /// Transport-neutral creation request.
    case create(CreateFileRequest)
    /// Transport-neutral read request.
    case read(ReadFileRequest)
    /// Transport-neutral update request.
    case update(UpdateFileRequest)
    /// Transport-neutral deletion request.
    case delete(DeleteFileRequest)
}
