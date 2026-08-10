/// Transport-neutral mutation boundary for recursive directory moves.
protocol DirectoryMoveService: Sendable {
    /// Moves one complete notes subtree without reading or rewriting its files.
    func move(_ request: MoveDirectoryRequest) async throws -> FileOperationOutput
}
