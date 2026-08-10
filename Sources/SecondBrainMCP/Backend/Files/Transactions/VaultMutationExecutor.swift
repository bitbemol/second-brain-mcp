/// Performs one prepared filesystem mutation and awaits its Git snapshot.
struct VaultMutationExecutor: Sendable {
    private let versioning: any VaultVersioning

    init(versioning: any VaultVersioning) {
        self.versioning = versioning
    }

    /// Runs under the caller's exclusive ``VaultAccessCoordinating`` lease.
    ///
    /// Cancellation is honored before persistence starts. Once it starts, the
    /// persistence-and-snapshot chain finishes before the lease is released.
    func execute(
        _ mutation: PreparedVaultMutation
    ) async throws -> FileOperationOutput {
        try Task.checkCancellation()
        let versioning = self.versioning
        return try await Task.detached {
            let output = try await mutation.perform()
            if mutation.requiresSnapshot {
                try await versioning.recordSnapshot()
            }
            return output
        }.value
    }
}
