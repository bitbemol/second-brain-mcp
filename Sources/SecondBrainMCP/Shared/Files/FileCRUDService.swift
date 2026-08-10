/// Transport-neutral service boundary for the compact file CRUD API.
///
/// Frontend adapters depend on this contract rather than a concrete backend
/// router. Requests and outputs remain shared values without exposing storage,
/// handler, Git, or receipt implementation details.
protocol FileCRUDService: Sendable {
    /// Creates a supported concrete file.
    ///
    /// - Parameter request: Validated transport-neutral creation input.
    /// - Returns: Format-specific presentation output.
    func create(_ request: CreateFileRequest) async throws -> FileOperationOutput

    /// Reads a supported concrete file.
    ///
    /// - Parameter request: Validated transport-neutral read input.
    /// - Returns: Format-specific text or image content.
    func read(_ request: ReadFileRequest) async throws -> FileOperationOutput

    /// Updates a supported writable file.
    ///
    /// - Parameter request: Validated transport-neutral update input.
    /// - Returns: Format-specific presentation output.
    func update(_ request: UpdateFileRequest) async throws -> FileOperationOutput

    /// Soft-deletes a supported writable file.
    ///
    /// - Parameter request: Validated transport-neutral deletion input.
    /// - Returns: Presentation output identifying the recoverable result.
    func delete(_ request: DeleteFileRequest) async throws -> FileOperationOutput
}
