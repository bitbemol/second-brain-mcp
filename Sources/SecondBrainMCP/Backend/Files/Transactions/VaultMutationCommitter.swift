/// Git sequencing shared by normal mutation execution and commit-only recovery.
struct VaultMutationCommitter: Sendable {
    private let git: GitRepository

    /// Creates a committer over one serialized repository adapter.
    init(git: GitRepository) {
        self.git = git
    }

    /// Commits the exact persisted result with both replay identities embedded.
    func commit(
        _ plan: VaultMutationPlan,
        output: FileOperationOutput,
        fingerprint: MutationRequestFingerprint
    ) async throws {
        guard let metadata = output.metadata,
              metadata.path == plan.path,
              metadata.mutationID == plan.mutationID else {
            throw MutationReceiptStore.ReceiptError.corrupt(plan.mutationID)
        }
        let identity = GitMutationIdentity(
            identifier: plan.mutationID,
            fingerprint: fingerprint
        )
        switch plan.kind {
        case .create, .update:
            guard let expectedRevision = metadata.revision else {
                throw MutationReceiptStore.ReceiptError.corrupt(
                    plan.mutationID
                )
            }
            try await git.commitChange(
                file: plan.path,
                expectedRevision: expectedRevision,
                maximumBytes: plan.format.maximumFileBytes,
                message: plan.commitMessage,
                identity: identity
            )
        case .delete:
            guard metadata.revision == nil else {
                throw MutationReceiptStore.ReceiptError.corrupt(
                    plan.mutationID
                )
            }
            try await git.commitDeletion(
                path: plan.path,
                message: plan.commitMessage,
                identity: identity
            )
        }
    }

    /// Detects a commit that succeeded before receipt finalization crashed.
    func alreadyCommitted(
        _ plan: VaultMutationPlan,
        fingerprint: MutationRequestFingerprint
    ) async throws -> Bool {
        return try await git.containsMutationCommit(
            identifier: plan.mutationID,
            fingerprint: fingerprint
        )
    }

    /// Repairs only the mutation-owned real-index entry after a crash between
    /// immutable ref update and index reconciliation.
    func reconcileCommitted(_ plan: VaultMutationPlan) async throws {
        try await git.reconcileCommittedChange(path: plan.path)
    }
}

/// Bounds diagnostics before persisting them in recovery receipts and audit logs.
enum VaultMutationFailureText {
    /// Prevents subprocess diagnostics from producing unbounded transaction data.
    static func bounded(_ error: any Error) -> String {
        String(String(describing: error).prefix(4_096))
    }
}
