/// Executes one storage mutation together with its required Git commit and audit.
///
/// Format handlers and persistence remain outside this actor. Its only job is to
/// serialize the supplied mutation closure with versioning and observability so
/// those transaction mechanics cannot leak back into routing.
actor VaultMutationExecutor {
    /// Failures that occur after a filesystem mutation reaches Git sequencing.
    enum ExecutionError: Error, CustomStringConvertible {
        /// Persistence succeeded, but the required Git commit failed.
        case gitCommitFailed(path: String, underlying: String)

        /// Human-readable transaction failure suitable for an MCP error response.
        var description: String {
            switch self {
            case .gitCommitFailed(let path, let underlying):
                return "Vault changed at \(path), but the required git commit failed: \(underlying)"
            }
        }
    }

    private let git: GitRepository
    private let audit: AuditLogger
    private let gate = AsyncExclusiveGate()

    /// Creates an executor for one vault's versioning and audit adapters.
    ///
    /// - Parameters:
    ///   - git: Serialized local Git integration.
    ///   - audit: Append-only operation log.
    init(git: GitRepository, audit: AuditLogger) {
        self.git = git
        self.audit = audit
    }

    /// Applies, commits, and audits a prepared storage mutation as one sequence.
    ///
    /// The storage result is returned unchanged. If storage fails, Git and audit
    /// are skipped. If Git fails after storage succeeds, the exceptional state is
    /// audited before ``ExecutionError/gitCommitFailed(path:underlying:)`` is thrown.
    ///
    /// - Parameters:
    ///   - plan: Stable metadata for Git and audit behavior.
    ///   - apply: Concrete storage operation supplied by the routed service.
    /// - Returns: The storage operation's result.
    func execute<Result: Sendable>(
        _ plan: VaultMutationPlan,
        apply: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let git = self.git
        let audit = self.audit
        return try await gate.withPermit {
            let result = try await apply()
            do {
                // Once persistence succeeds, finish versioning even if the MCP
                // request is canceled. Interrupting here would leave changed bytes
                // outside Git while falsely presenting cancellation as rollback.
                try await Task.detached {
                    try await Self.commit(plan, using: git)
                }.value
            } catch {
                await audit.log(
                    operation: plan.kind.fileOperation,
                    path: plan.path,
                    details: "\(plan.handler.rawValue); git commit failed: \(error)"
                )
                throw ExecutionError.gitCommitFailed(
                    path: plan.path,
                    underlying: "\(error)"
                )
            }
            await audit.log(
                operation: plan.kind.fileOperation,
                path: plan.path,
                details: plan.handler.rawValue
            )
            return result
        }
    }

    private static func commit(
        _ plan: VaultMutationPlan,
        using git: GitRepository
    ) async throws {
        let message = "[SecondBrainMCP] \(plan.kind.commitVerb) \(plan.format.rawValue): \(plan.path)"
        switch plan.kind {
        case .create, .update:
            try await git.commitChange(files: [plan.path], message: message)
        case .delete:
            try await git.commitDeletion(path: plan.path, message: message)
        }
    }
}
