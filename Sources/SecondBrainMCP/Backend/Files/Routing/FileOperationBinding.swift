/// Associates a reusable operation function with its allowed vault areas.
struct FileOperationBinding<Handler: Sendable>: Sendable {
    /// Structural areas accepted by the handler.
    let allowedAreas: Set<VaultArea>
    /// Reusable operation function.
    let execute: Handler
}

/// Create binding plus the public payload contract advertised to clients.
struct CreateOperationBinding: Sendable {
    /// Structural areas accepted by the handler.
    let allowedAreas: Set<VaultArea>
    /// Caller input required by this format.
    let contract: FileCreateContract
    /// Persistence-free create function.
    let execute: CreateFileFunction

    init(
        allowedAreas: Set<VaultArea>,
        contract: FileCreateContract = .content,
        execute: @escaping CreateFileFunction
    ) {
        self.allowedAreas = allowedAreas
        self.contract = contract
        self.execute = execute
    }
}

/// Read-operation specialization of the common binding.
typealias ReadOperationBinding = FileOperationBinding<ReadFileFunction>

/// Update binding plus the modes accepted by its shared edit pipeline.
struct UpdateOperationBinding: Sendable {
    /// Structural areas accepted by the handler.
    let allowedAreas: Set<VaultArea>
    /// Update modes discoverable by clients.
    let supportedModes: Set<FileUpdateMode>
    /// Persistence-free update function.
    let execute: UpdateFileFunction

    init(
        allowedAreas: Set<VaultArea>,
        supportedModes: Set<FileUpdateMode> = Set(FileUpdateMode.allCases),
        execute: @escaping UpdateFileFunction
    ) {
        self.allowedAreas = allowedAreas
        self.supportedModes = supportedModes
        self.execute = execute
    }
}

/// Delete-operation specialization of the common binding.
typealias DeleteOperationBinding = FileOperationBinding<DeleteFileFunction>
