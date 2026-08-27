/// Transport-neutral mutation boundary for atomic file and directory moves.
protocol PathMoveService: Sendable {
    /// Moves one supported file or one complete notes subtree without rewriting bytes.
    func move(_ request: MovePathRequest) async throws -> FileOperationOutput
}
