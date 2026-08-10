/// Executes persistence, vault versioning, audit, and receipt finalization in order.
///
/// Version-control state and serialization belong exclusively to ``VaultVersioning``.
/// This actor coordinates only mutation identity, persistence, audit, and receipts.
/// Recovery policy lives in ``VaultMutationRecovery``.
///
/// Transaction records cover cooperating-process concurrency, cancellation,
/// client timeout, and ordinary process termination. They do not make vault
/// bytes, snapshots, and the external receipt directory one atomic filesystem
/// transaction; uncertain retries therefore fail closed for their own mutation ID.
actor VaultMutationExecutor {
    /// Failures that occur at or after persistence sequencing.
    enum ExecutionError: Error, CustomStringConvertible, Sendable {
        /// Persistence succeeded, but the required vault snapshot failed.
        case snapshotFailed(
            path: String,
            mutationID: MutationID,
            underlying: String
        )
        /// A process stopped after this mutation's durable point of no return.
        case priorAttemptOutcomeUnknown(MutationID)
        /// A failed receipt lacks the state needed for safe snapshot recovery.
        case priorAttemptFailed(MutationID, underlying: String)
        /// Bytes and versioning completed, but the replayable result could not be saved.
        case receiptFinalizationFailed(path: String, underlying: String)
        /// Snapshotting failed and its recovery receipt could not be saved.
        case recoveryStatePersistenceFailed(path: String, underlying: String)
        /// Stored bytes no longer match the outcome awaiting snapshot recovery.
        case recoveryStateChanged(path: String, mutationID: MutationID)

        /// Human-readable transaction failure suitable for an MCP error response.
        var description: String {
            switch self {
            case .snapshotFailed(let path, let identifier, let underlying):
                return "Vault changed at \(path), but its snapshot failed: \(underlying). Retry the exact same request with mutation_id \(identifier); persistence will not run again"
            case .priorAttemptOutcomeUnknown(let identifier):
                return "Mutation \(identifier) stopped after its point of no return; its outcome is unknown and it was not applied again"
            case .priorAttemptFailed(let identifier, let underlying):
                return "Mutation \(identifier) previously changed the vault but cannot be recovered safely: \(underlying)"
            case .receiptFinalizationFailed(let path, let underlying):
                return "Vault and versioning changed at \(path), but the retry receipt could not be finalized: \(underlying)"
            case .recoveryStatePersistenceFailed(let path, let underlying):
                return "Vault changed at \(path), but its recovery state could not be saved: \(underlying)"
            case .recoveryStateChanged(let path, let identifier):
                return "Vault state at \(path) no longer matches mutation \(identifier), so snapshot recovery was refused"
            }
        }
    }

    private let versioning: any VaultVersioning
    private let audit: AuditLogger
    private let receipts: MutationReceiptStore

    /// Creates an executor for one vault's versioning and audit adapters.
    init(
        versioning: any VaultVersioning,
        audit: AuditLogger,
        receipts: MutationReceiptStore
    ) {
        self.versioning = versioning
        self.audit = audit
        self.receipts = receipts
    }

    /// Prepares and executes a retry-safe mutation with one durable outcome.
    ///
    /// The mutation identifier is locked only against duplicate requests. Unrelated
    /// mutations may persist concurrently; VaultVersioning alone serializes the
    /// vault snapshot that follows persistence.
    func executeIdempotent(
        plan: VaultMutationPlan,
        fingerprint: MutationRequestFingerprint,
        prepare: @escaping @Sendable () async throws -> PreparedVaultMutation
    ) async throws -> FileOperationOutput {
        let versioning = self.versioning
        let audit = self.audit
        let receipts = self.receipts

        let identifier = plan.mutationID
        let recovery = VaultMutationRecovery(
            receipts: receipts,
            versioning: versioning,
            audit: audit
        )

        return try await receipts.withIdentityLock(identifier) {
            try Task.checkCancellation()
            let initial = try await recovery.preflight(
                plan: plan,
                identifier: identifier,
                fingerprint: fingerprint
            )
            if case .result(let output) = initial { return output }

            let prepared = try await prepare()

            try Task.checkCancellation()
            let rechecked = try await recovery.preflight(
                plan: plan,
                identifier: identifier,
                fingerprint: fingerprint
            )
            if case .result(let output) = rechecked { return output }

            try await receipts.updatingReceipt { store in
                try store.saveInProgress(
                    identifier: identifier,
                    fingerprint: fingerprint
                )
                try store.markPersistenceStarted(
                    identifier: identifier,
                    fingerprint: fingerprint
                )
            }
            return try await Task.detached {
                try await Self.executePreparedCritical(
                    plan,
                    mutation: prepared,
                    versioning: versioning,
                    audit: audit,
                    receiptContext: (receipts, identifier, fingerprint)
                )
            }.value
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
        versioning: any VaultVersioning,
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

        if mutation.requiresSnapshot {
            do {
                try await Task.detached {
                    try await versioning.recordSnapshot()
                }.value
            } catch {
                let failure = VaultMutationFailureText.bounded(error)
                do {
                    try await receiptContext.store.updatingReceipt { store in
                        try store.savePostPersistenceFailure(
                            identifier: receiptContext.identifier,
                            fingerprint: receiptContext.fingerprint,
                            output: output,
                            recoveryEvidence: persisted.recoveryEvidence,
                            failure: failure
                        )
                    }
                } catch {
                    await audit.log(
                        operation: VaultOperation(plan.kind.fileOperation),
                        path: plan.path,
                        details: "\(plan.auditDetails); recovery state persistence failed: \(error)"
                    )
                    throw ExecutionError.recoveryStatePersistenceFailed(
                        path: plan.path,
                        underlying: "snapshot failure: \(failure); receipt failure: \(error)"
                    )
                }
                await audit.log(
                    operation: VaultOperation(plan.kind.fileOperation),
                    path: plan.path,
                    details: "\(plan.auditDetails); snapshot failed: \(failure)"
                )
                throw ExecutionError.snapshotFailed(
                    path: plan.path,
                    mutationID: plan.mutationID,
                    underlying: failure
                )
            }
        }

        await audit.log(
            operation: VaultOperation(plan.kind.fileOperation),
            path: plan.path,
            details: mutation.requiresSnapshot
                ? plan.auditDetails
                : "\(plan.auditDetails); no changes"
        )

        do {
            try await receiptContext.store.updatingReceipt { store in
                try store.save(
                    identifier: receiptContext.identifier,
                    fingerprint: receiptContext.fingerprint,
                    output: output
                )
            }
        } catch {
            throw ExecutionError.receiptFinalizationFailed(
                path: plan.path,
                underlying: "\(error)"
            )
        }
        return output
    }
}
