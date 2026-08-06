import Foundation

/// Reconciles durable transaction state before a mutation may persist.
///
/// Callers hold the process-local gate and vault-wide process lock. This type
/// owns stale-marker cleanup, commit-only retry, and recovery-state validation.
struct VaultMutationRecovery: Sendable {
    /// Outcome of checking durable transaction state.
    enum Preflight: Sendable {
        /// No receipt or active transaction prevents persistence.
        case proceed
        /// Replay or commit-only recovery produced the public result.
        case result(FileOperationOutput)
    }

    private let receipts: MutationReceiptStore
    private let committer: VaultMutationCommitter
    private let audit: AuditLogger

    /// Creates recovery orchestration for one vault transaction boundary.
    init(
        receipts: MutationReceiptStore,
        git: GitRepository,
        audit: AuditLogger
    ) {
        self.receipts = receipts
        self.committer = VaultMutationCommitter(git: git)
        self.audit = audit
    }

    /// Clears safe stale state, replays completion, or performs commit-only recovery.
    func preflight(
        plan: VaultMutationPlan,
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint
    ) async throws -> Preflight {
        let active: MutationReceiptStore.ActiveTransaction?
        do {
            active = try receipts.activeTransaction()
        } catch {
            throw VaultMutationExecutor.ExecutionError.recoveryRequired(
                activeMutation: nil
            )
        }

        if let active {
            let lookup: MutationReceiptStore.Lookup
            do {
                guard let stored = try receipts.replay(
                    identifier: active.identifier,
                    fingerprint: active.fingerprint
                ) else {
                    throw VaultMutationExecutor.ExecutionError.recoveryRequired(
                        activeMutation: active.identifier
                    )
                }
                lookup = stored
            } catch let error as VaultMutationExecutor.ExecutionError {
                throw error
            } catch {
                throw VaultMutationExecutor.ExecutionError.recoveryRequired(
                    activeMutation: active.identifier
                )
            }

            switch lookup {
            case .completed:
                do {
                    try receipts.clearActiveTransaction(active)
                } catch {
                    throw VaultMutationExecutor.ExecutionError.recoveryRequired(
                        activeMutation: active.identifier
                    )
                }
            case .prePersistence, .outcomeUnknown:
                throw VaultMutationExecutor.ExecutionError.recoveryRequired(
                    activeMutation: active.identifier
                )
            case .failedAfterPersistence(let output, let recoveryEvidence, _):
                guard active.identifier == identifier else {
                    throw VaultMutationExecutor.ExecutionError.recoveryRequired(
                        activeMutation: active.identifier
                    )
                }
                guard active.fingerprint == fingerprint else {
                    throw MutationReceiptStore.ReceiptError.identifierReused(
                        identifier
                    )
                }
                guard let output,
                      output.metadata?.mutationID == identifier else {
                    throw VaultMutationExecutor.ExecutionError.recoveryRequired(
                        activeMutation: active.identifier
                    )
                }
                return .result(try await recoverGitCommit(
                    plan: plan,
                    active: active,
                    output: output,
                    recoveryEvidence: recoveryEvidence
                ))
            }
        }

        guard let lookup = try receipts.replay(
            identifier: identifier,
            fingerprint: fingerprint
        ) else {
            return .proceed
        }
        switch lookup {
        case .completed(let output):
            return .result(output)
        case .prePersistence:
            try receipts.clearPrePersistenceIntent(
                identifier: identifier,
                fingerprint: fingerprint
            )
            return .proceed
        case .outcomeUnknown:
            throw VaultMutationExecutor.ExecutionError
                .priorAttemptOutcomeUnknown(identifier)
        case .failedAfterPersistence(_, _, let failure):
            // A legacy receipt without a global marker cannot be recovered because
            // intervening history may already have made its original order unclear.
            throw VaultMutationExecutor.ExecutionError.priorAttemptFailed(
                identifier,
                underlying: failure
            )
        }
    }

    /// Retries only Git for an exact failed transaction, then finalizes it.
    private func recoverGitCommit(
        plan: VaultMutationPlan,
        active: MutationReceiptStore.ActiveTransaction,
        output: FileOperationOutput,
        recoveryEvidence: VaultMutationRecoveryEvidence?
    ) async throws -> FileOperationOutput {
        let alreadyCommitted: Bool
        do {
            alreadyCommitted = try await committer.alreadyCommitted(plan)
            // Finalization is allowed only while the public outcome still
            // describes the vault, even if Git already committed before a crash.
            try validateRecoveryState(
                plan: plan,
                output: output,
                recoveryEvidence: recoveryEvidence,
                identifier: active.identifier
            )
            if !alreadyCommitted {
                // Recovery is past persistence. Keep Git alive if the MCP caller
                // cancels while awaiting the commit-only attempt.
                try await Task.detached {
                    try await committer.commit(plan)
                }.value
            }
        } catch let error as VaultMutationExecutor.ExecutionError {
            throw error
        } catch {
            let failure = VaultMutationFailureText.bounded(error)
            do {
                try receipts.savePostPersistenceFailure(
                    identifier: active.identifier,
                    fingerprint: active.fingerprint,
                    output: output,
                    recoveryEvidence: recoveryEvidence,
                    failure: failure
                )
            } catch {
                await audit.log(
                    operation: plan.kind.fileOperation,
                    path: plan.path,
                    details: "\(plan.auditDetails); recovery state persistence failed: \(error)"
                )
                throw VaultMutationExecutor.ExecutionError
                    .recoveryStatePersistenceFailed(
                        path: plan.path,
                        underlying: "git failure: \(failure); receipt failure: \(error)"
                    )
            }
            await audit.log(
                operation: plan.kind.fileOperation,
                path: plan.path,
                details: "\(plan.auditDetails); recovery git commit failed: \(failure)"
            )
            throw VaultMutationExecutor.ExecutionError.gitCommitFailed(
                path: plan.path,
                mutationID: plan.mutationID,
                underlying: failure
            )
        }

        await audit.log(
            operation: plan.kind.fileOperation,
            path: plan.path,
            details: alreadyCommitted
                ? "\(plan.auditDetails); finalized previously recovered git commit"
                : "\(plan.auditDetails); recovered git commit after prior failure"
        )
        do {
            try receipts.save(
                identifier: active.identifier,
                fingerprint: active.fingerprint,
                output: output
            )
            try receipts.clearActiveTransaction(active)
        } catch {
            throw VaultMutationExecutor.ExecutionError.receiptFinalizationFailed(
                path: plan.path,
                underlying: "\(error)"
            )
        }
        guard let metadata = output.metadata else {
            throw MutationReceiptStore.ReceiptError.corrupt(active.identifier)
        }
        return output.withMetadata(metadata.markingReplayed())
    }

    /// Confirms commit-only recovery still describes the persisted vault state.
    private func validateRecoveryState(
        plan: VaultMutationPlan,
        output: FileOperationOutput,
        recoveryEvidence: VaultMutationRecoveryEvidence?,
        identifier: MutationID
    ) throws {
        do {
            try plan.target.revalidate()
            switch plan.kind {
            case .delete:
                guard !FileManager.default.fileExists(atPath: plan.target.url.path) else {
                    throw stateChanged(plan: plan, identifier: identifier)
                }
                try validateDeletedArtifact(
                    plan: plan,
                    recoveryEvidence: recoveryEvidence,
                    identifier: identifier
                )
            case .create, .update:
                guard let expected = output.metadata?.revision else {
                    throw stateChanged(plan: plan, identifier: identifier)
                }
                let metadata = try VaultFileInspector.inspect(plan.target.readable)
                try FileResourcePolicy.validate(
                    bytes: metadata.byteCount,
                    format: plan.format,
                    path: plan.path
                )
                let data = try BoundedFileReader.read(
                    from: plan.target.url,
                    maximumBytes: plan.format.maximumFileBytes,
                    path: plan.path
                )
                let current = FileSnapshot(data: data, modifiedDate: nil).revision
                guard current == expected else {
                    throw stateChanged(plan: plan, identifier: identifier)
                }
            }
        } catch let error as VaultMutationExecutor.ExecutionError {
            throw error
        } catch {
            throw stateChanged(plan: plan, identifier: identifier)
        }
    }

    /// Confirms a recovered delete still points to the exact bytes in trash.
    private func validateDeletedArtifact(
        plan: VaultMutationPlan,
        recoveryEvidence: VaultMutationRecoveryEvidence?,
        identifier: MutationID
    ) throws {
        guard case .softDeleted(let trashPath, let expectedRevision) =
                recoveryEvidence,
              (trashPath as NSString).deletingLastPathComponent == ".trash",
              !PathValidator.containsSymbolicLinkComponent(
                relativePath: trashPath,
                root: plan.target.vaultPath
              ) else {
            throw stateChanged(plan: plan, identifier: identifier)
        }

        let resolvedPath = try PathValidator.resolve(
            relativePath: trashPath,
            root: plan.target.vaultPath,
            allowedExtensions: plan.format.extensions
        )
        let metadata = try FileManager.default.attributesOfItem(atPath: resolvedPath)
        guard metadata[.type] as? FileAttributeType == .typeRegular,
              let storedSize = metadata[.size] as? NSNumber,
              storedSize.int64Value >= 0,
              storedSize.uint64Value <= UInt64(plan.format.maximumFileBytes) else {
            throw stateChanged(plan: plan, identifier: identifier)
        }
        let data = try BoundedFileReader.read(
            from: URL(fileURLWithPath: resolvedPath),
            maximumBytes: plan.format.maximumFileBytes,
            path: trashPath
        )
        let currentRevision = FileSnapshot(data: data, modifiedDate: nil).revision
        guard currentRevision == expectedRevision else {
            throw stateChanged(plan: plan, identifier: identifier)
        }
    }

    private func stateChanged(
        plan: VaultMutationPlan,
        identifier: MutationID
    ) -> VaultMutationExecutor.ExecutionError {
        .recoveryStateChanged(path: plan.path, mutationID: identifier)
    }
}
