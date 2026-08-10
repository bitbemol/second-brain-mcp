/// Backend-only evidence needed to prove a persisted mutation before recovery.
enum VaultMutationRecoveryEvidence: Sendable, Codable {
    /// Source inode captured before an atomic directory rename begins.
    case directoryMoveIntent(
        sourcePath: String,
        destinationPath: String,
        identity: DirectoryTreeStore.Identity,
        summary: DirectoryMoveSecurityPreflight.Manifest.Summary
    )
    /// Exact soft-deleted artifact that must still exist under vault trash.
    case softDeleted(path: String, revision: FileRevision)
    /// Directory inode that must remain at the recovered move destination.
    case movedDirectory(
        sourcePath: String,
        destinationPath: String,
        identity: DirectoryTreeStore.Identity,
        summary: DirectoryMoveSecurityPreflight.Manifest.Summary
    )
}

/// Result returned by a persistence closure before snapshotting begins.
struct PersistedVaultMutation: Sendable {
    /// Public operation result returned or retained in the replay receipt.
    let output: FileOperationOutput
    /// Backend-only evidence needed by a later snapshot retry.
    let recoveryEvidence: VaultMutationRecoveryEvidence?
}

/// Persistence work prepared under an exclusive notes-path lease.
struct PreparedVaultMutation: Sendable {
    /// Whether changed bytes require a vault snapshot.
    let requiresSnapshot: Bool
    /// Applies prepared bytes or deletion and returns output plus recovery evidence.
    let perform: @Sendable () async throws -> PersistedVaultMutation

    /// Creates ordinary create/update persistence without extra evidence.
    init(
        requiresSnapshot: Bool,
        perform: @escaping @Sendable () async throws -> FileOperationOutput
    ) {
        self.requiresSnapshot = requiresSnapshot
        self.perform = {
            PersistedVaultMutation(
                output: try await perform(),
                recoveryEvidence: nil
            )
        }
    }

    /// Creates persistence that produces backend-only recovery evidence.
    init(
        requiresSnapshot: Bool,
        performWithRecoveryEvidence:
            @escaping @Sendable () async throws -> PersistedVaultMutation
    ) {
        self.requiresSnapshot = requiresSnapshot
        self.perform = performWithRecoveryEvidence
    }
}
