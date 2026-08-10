/// Associates a reusable operation function with its allowed vault areas.
struct FileOperationBinding<Handler: Sendable>: Sendable {
    /// Structural areas accepted by the handler.
    let allowedAreas: Set<VaultArea>
    /// Reusable operation function.
    let execute: Handler
}

/// Create-operation specialization of the common binding.
typealias CreateOperationBinding = FileOperationBinding<CreateFileFunction>

/// Read-operation specialization of the common binding.
typealias ReadOperationBinding = FileOperationBinding<ReadFileFunction>

/// Update-operation specialization of the common binding.
typealias UpdateOperationBinding = FileOperationBinding<UpdateFileFunction>

/// Delete-operation specialization of the common binding.
typealias DeleteOperationBinding = FileOperationBinding<DeleteFileFunction>
