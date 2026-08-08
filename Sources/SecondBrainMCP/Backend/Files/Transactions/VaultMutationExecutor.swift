/// Executes persistence, Git, audit, and durable receipt finalization in order.
///
/// A local FIFO gate and required cross-process lock serialize the Git working tree.
/// Recovery policy lives in ``VaultMutationRecovery`` so this actor remains the
/// small sequencing interface used by the routed file service.
///
/// Transaction records cover cooperating-process concurrency, cancellation,
/// client timeout, and ordinary process termination. They do not make vault
/// bytes, Git, and the external receipt directory atomic across sudden power or
/// storage failure; recovery is conservative when the active marker survives.
actor VaultMutationExecutor {
    /// Failures that occur at or after transaction sequencing.
    enum ExecutionError: Error, CustomStringConvertible, Sendable {
        /// Persistence succeeded, but the required Git commit failed.
        case gitCommitFailed(
            path: String,
            mutationID: MutationID,
            underlying: String
        )
        /// A legacy process stopped after its durable point of no return.
        case priorAttemptOutcomeUnknown(MutationID)
        /// A legacy failed receipt cannot be recovered without its global marker.
        case priorAttemptFailed(MutationID, underlying: String)
        /// A vault-wide transaction must be recovered before mutations may run.
        case recoveryRequired(activeMutation: MutationID?)
        /// Bytes and Git completed, but the replayable result could not be saved.
        case receiptFinalizationFailed(path: String, underlying: String)
        /// Git failed and the commit-only recovery receipt could not be saved.
        case recoveryStatePersistenceFailed(path: String, underlying: String)
        /// Stored bytes no longer match the outcome awaiting commit recovery.
        case recoveryStateChanged(path: String, mutationID: MutationID)
        /// Human-readable transaction failure suitable for an MCP error response.
        var description: String {
            switch self {
            case .gitCommitFailed(let path, let identifier, let underlying):
                return "Vault changed at \(path), but the required git commit failed: \(underlying). Retry the exact same request with mutation_id \(identifier); persistence will not run again and other mutations remain blocked until recovery completes"
            case .priorAttemptOutcomeUnknown(let identifier):
                return "Mutation \(identifier) stopped after its point of no return; its outcome is unknown and it was not applied again"
            case .priorAttemptFailed(let identifier, let underlying):
                return "Mutation \(identifier) previously changed the vault but did not complete: \(underlying)"
            case .recoveryRequired(let identifier):
                if let identifier {
                    return "Vault mutation \(identifier) requires recovery; all other mutations remain blocked. Retry its exact original request when it is known to have failed after persistence; an outcome-unknown transaction requires manual reconciliation"
                }
                return "Vault mutation recovery is required and all mutations remain blocked until the active transaction is manually reconciled"
            case .receiptFinalizationFailed(let path, let underlying):
                return "Vault and git changed at \(path), but the retry receipt could not be finalized: \(underlying)"
            case .recoveryStatePersistenceFailed(let path, let underlying):
                return "Vault changed at \(path), but its recovery state could not be saved: \(underlying). All mutations remain blocked and manual recovery is required"
            case .recoveryStateChanged(let path, let identifier):
                return "Vault state at \(path) no longer matches mutation \(identifier), so commit-only recovery was refused. All mutations remain blocked until the change is manually reconciled"
            }
        }
    }

    private let git: GitRepository
    private let audit: AuditLogger
    private let processMutationLock: POSIXAdvisoryFileLock
    private let receipts: MutationReceiptStore
    private let gate = AsyncExclusiveGate()

    /// Creates an executor for one vault's versioning and audit adapters.
    init(
        git: GitRepository,
        audit: AuditLogger,
        processMutationLock: POSIXAdvisoryFileLock,
        receipts: MutationReceiptStore
    ) {
        self.git = git
        self.audit = audit
        self.processMutationLock = processMutationLock
        self.receipts = receipts
    }

    /// Prepares and executes a retry-safe mutation with one durable outcome.
    ///
    /// Preparation runs outside the vault-wide lock. Durable state is rechecked
    /// after preparation before intent and the active marker are written.
    func executeIdempotent(
        plan: VaultMutationPlan,
        fingerprint: MutationRequestFingerprint,
        prepare: @escaping @Sendable () async throws -> PreparedVaultMutation
    ) async throws -> FileOperationOutput {
        let git = self.git
        let audit = self.audit
        let gate = self.gate
        let processMutationLock = self.processMutationLock
        let receipts = self.receipts

        let identifier = plan.mutationID
        let recovery = VaultMutationRecovery(
            receipts: receipts,
            git: git,
            audit: audit
        )

        return try await receipts.withIdentityLock(identifier) {
            let initial = try await gate.withPermit {
                try await Self.withProcessMutationLock(processMutationLock) {
                    try Task.checkCancellation()
                    return try await recovery.preflight(
                        plan: plan,
                        identifier: identifier,
                        fingerprint: fingerprint
                    )
                }
            }
            if case .result(let output) = initial { return output }

            let prepared = try await prepare()
            return try await gate.withPermit {
                try await Self.withProcessMutationLock(processMutationLock) {
                    try Task.checkCancellation()
                    let rechecked = try await recovery.preflight(
                        plan: plan,
                        identifier: identifier,
                        fingerprint: fingerprint
                    )
                    if case .result(let output) = rechecked { return output }

                    // Both records are fsynced before persistence can begin.
                    try receipts.saveInProgress(
                        identifier: identifier,
                        fingerprint: fingerprint
                    )
                    try receipts.saveActiveTransaction(
                        identifier: identifier,
                        fingerprint: fingerprint
                    )
                    return try await Task.detached {
                        try await Self.executePreparedCritical(
                            plan,
                            mutation: prepared,
                            git: git,
                            audit: audit,
                            receiptContext: (receipts, identifier, fingerprint)
                        )
                    }.value
                }
            }
        }
    }

    private typealias ReceiptContext = (
        store: MutationReceiptStore,
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint
    )

    private static func executePreparedCritical(
        _ plan: VaultMutationPlan,
        mutation: PreparedVaultMutation,
        git: GitRepository,
        audit: AuditLogger,
        receiptContext: ReceiptContext
    ) async throws -> FileOperationOutput {
        let persisted: PersistedVaultMutation
        do {
            persisted = try await mutation.perform()
        } catch {
            await audit.log(
                operation: VaultOperation(plan.kind.fileOperation),
                path: plan.path,
                details: "\(plan.auditDetails); persistence outcome unknown: \(error)"
            )
            throw error
        }
        let output = persisted.output

        if mutation.requiresCommit {
            do {
                let committer = VaultMutationCommitter(git: git)
                try await Task.detached {
                    try await committer.commit(
                        plan,
                        output: output,
                        fingerprint: receiptContext.fingerprint
                    )
                }.value
            } catch {
                let failure = VaultMutationFailureText.bounded(error)
                do {
                    try receiptContext.store.savePostPersistenceFailure(
                        identifier: receiptContext.identifier,
                        fingerprint: receiptContext.fingerprint,
                        output: output,
                        recoveryEvidence: persisted.recoveryEvidence,
                        failure: failure
                    )
                } catch {
                    await audit.log(
                        operation: VaultOperation(plan.kind.fileOperation),
                        path: plan.path,
                        details: "\(plan.auditDetails); recovery state persistence failed: \(error)"
                    )
                    throw ExecutionError.recoveryStatePersistenceFailed(
                        path: plan.path,
                        underlying: "git failure: \(failure); receipt failure: \(error)"
                    )
                }
                await audit.log(
                    operation: VaultOperation(plan.kind.fileOperation),
                    path: plan.path,
                    details: "\(plan.auditDetails); git commit failed: \(failure)"
                )
                throw ExecutionError.gitCommitFailed(
                    path: plan.path,
                    mutationID: plan.mutationID,
                    underlying: failure
                )
            }
        }

        await audit.log(
            operation: VaultOperation(plan.kind.fileOperation),
            path: plan.path,
            details: mutation.requiresCommit
                ? plan.auditDetails
                : "\(plan.auditDetails); no changes"
        )

        let active = MutationReceiptStore.ActiveTransaction(
            identifier: receiptContext.identifier,
            fingerprint: receiptContext.fingerprint
        )
        do {
            try receiptContext.store.save(
                identifier: receiptContext.identifier,
                fingerprint: receiptContext.fingerprint,
                output: output
            )
            try receiptContext.store.clearActiveTransaction(active)
        } catch {
            throw ExecutionError.receiptFinalizationFailed(
                path: plan.path,
                underlying: "\(error)"
            )
        }
        return output
    }

    private static func withProcessMutationLock<Result: Sendable>(
        _ lock: POSIXAdvisoryFileLock,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await lock.withLock(.exclusive, operation: operation)
    }
}
