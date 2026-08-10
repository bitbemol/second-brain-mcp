/// Persistence work prepared under the vault's exclusive mutation lease.
struct PreparedVaultMutation: Sendable {
    /// Whether changed bytes require a vault snapshot.
    let requiresSnapshot: Bool
    /// Applies the prepared filesystem mutation and returns its public output.
    let perform: @Sendable () async throws -> FileOperationOutput
}
