/// Performs one prepared filesystem mutation and awaits its Git snapshot.
struct VaultMutationExecutor: Sendable {
    private let versioning: any VaultVersioning

    init(versioning: any VaultVersioning) {
        self.versioning = versioning
    }

    /// Preparation is persistence-free and remains inside the caller's exclusive lease.
    func prepare(
        _ operation: @Sendable () async throws -> PreparedVaultMutation
    ) async throws -> PreparedVaultMutation {
        do {
            try Task.checkCancellation()
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MutationFailure.beforePersistence(error)
        }
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
            do {
                let output = try await mutation.perform()
                if mutation.requiresSnapshot {
                    if let paths = mutation.snapshotPaths {
                        try await versioning.recordSnapshot(changing: paths)
                    } else {
                        try await versioning.recordSnapshot()
                    }
                }
                return output
            } catch let failure as MutationFailure {
                // A nested preparation failure from persistence/versioning is not evidence
                // that this outer operation left the vault untouched.
                throw MutationFailure.afterPersistenceStarted(failure.underlying)
            }
        }.value
    }
}
