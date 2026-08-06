/// Backend-only evidence needed to prove a persisted mutation before recovery.
enum VaultMutationRecoveryEvidence: Sendable, Codable {
    /// Exact soft-deleted artifact that must still exist under vault trash.
    case softDeleted(path: String, revision: FileRevision)
}

/// Result returned by a persistence closure before Git sequencing begins.
struct PersistedVaultMutation: Sendable {
    /// Public operation result returned or retained in the replay receipt.
    let output: FileOperationOutput
    /// Backend-only evidence needed by a later commit-only retry.
    let recoveryEvidence: VaultMutationRecoveryEvidence?
}

/// Persistence work prepared under an exclusive notes-path lease.
struct PreparedVaultMutation: Sendable {
    /// Whether successful execution requires a Git commit.
    let requiresCommit: Bool
    /// Applies prepared bytes or deletion and returns output plus recovery evidence.
    let perform: @Sendable () async throws -> PersistedVaultMutation

    /// Creates ordinary create/update persistence without extra evidence.
    init(
        requiresCommit: Bool,
        perform: @escaping @Sendable () async throws -> FileOperationOutput
    ) {
        self.requiresCommit = requiresCommit
        self.perform = {
            PersistedVaultMutation(
                output: try await perform(),
                recoveryEvidence: nil
            )
        }
    }

    /// Creates persistence that produces backend-only recovery evidence.
    init(
        requiresCommit: Bool,
        performWithRecoveryEvidence:
            @escaping @Sendable () async throws -> PersistedVaultMutation
    ) {
        self.requiresCommit = requiresCommit
        self.perform = performWithRecoveryEvidence
    }
}
