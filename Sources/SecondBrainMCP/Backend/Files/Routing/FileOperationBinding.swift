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

/// Read behavior and its snapshot-owning admission boundary.
struct ReadOperationBinding: Sendable {
    let allowedAreas: Set<VaultArea>
    let execute: ReadFileFunction
    let metadata: ReadFileFunction?
    let admission: ReadOperationAdmission

    init(
        allowedAreas: Set<VaultArea>,
        metadata: ReadFileFunction? = nil,
        admission: @escaping ReadOperationAdmission = { try await $0() },
        execute: @escaping ReadFileFunction
    ) {
        self.allowedAreas = allowedAreas
        self.execute = execute
        self.metadata = metadata
        self.admission = admission
    }
}

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
