/// One atomic rename of a complete subtree under `notes/`.
struct MoveDirectoryRequest: Codable, Equatable, Sendable {
    /// Stable transport-independent domain used by idempotency fingerprints.
    static let operationIdentifier = "move_directory"

    /// Caller-generated identity used to replay the exact mutation safely.
    let mutationID: MutationID
    /// Existing vault-relative directory under `notes/`.
    let sourcePath: String
    /// Exact new vault-relative directory path under `notes/`.
    let destinationPath: String
}

/// Transport-neutral mutation boundary for recursive directory moves.
protocol DirectoryMoveService: Sendable {
    /// Moves one complete notes subtree without reading or rewriting its files.
    func move(_ request: MoveDirectoryRequest) async throws -> FileOperationOutput
}

/// Public request limits for directory moves.
enum DirectoryMoveRequestLimits {
    /// Paths remain well below filesystem and transport amplification ceilings.
    static let maximumPathBytes = 4 * 1_024
}
