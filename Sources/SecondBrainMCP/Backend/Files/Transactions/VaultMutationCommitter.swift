/// Git sequencing shared by normal mutation execution and commit-only recovery.
struct VaultMutationCommitter: Sendable {
    private let git: GitRepository

    /// Creates a committer over one serialized repository adapter.
    init(git: GitRepository) {
        self.git = git
    }

    /// Commits the plan's exact path with its stable mutation-aware message.
    func commit(_ plan: VaultMutationPlan) async throws {
        switch plan.kind {
        case .create, .update:
            try await git.commitChange(
                files: [plan.path],
                message: plan.commitMessage
            )
        case .delete:
            try await git.commitDeletion(
                path: plan.path,
                message: plan.commitMessage
            )
        }
    }

    /// Detects a commit that succeeded before receipt finalization crashed.
    func alreadyCommitted(_ plan: VaultMutationPlan) async throws -> Bool {
        return try await git.containsMutationCommit(
            identifier: plan.mutationID,
            path: plan.path
        )
    }
}

/// Bounds diagnostics before persisting them in recovery receipts and audit logs.
enum VaultMutationFailureText {
    /// Prevents subprocess diagnostics from producing unbounded transaction data.
    static func bounded(_ error: any Error) -> String {
        String(String(describing: error).prefix(4_096))
    }
}
