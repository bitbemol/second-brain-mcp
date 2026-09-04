/// Persistence work prepared under the vault's exclusive mutation lease.
struct PreparedVaultMutation: Sendable {
    /// Whether changed bytes require a vault snapshot.
    let requiresSnapshot: Bool
    /// Canonical notes paths changed by this validated mutation.
    /// Nil requests full reconciliation, retained for recursive directory moves.
    let snapshotPaths: [String]?
    /// Applies the prepared filesystem mutation and returns its public output.
    let perform: @Sendable () async throws -> FileOperationOutput

    init(
        requiresSnapshot: Bool,
        snapshotPaths: [String]? = nil,
        perform: @escaping @Sendable () async throws -> FileOperationOutput
    ) {
        self.requiresSnapshot = requiresSnapshot
        self.snapshotPaths = snapshotPaths
        self.perform = perform
    }
}
