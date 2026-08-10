import Foundation

/// Reconciles one mutation's durable receipt before persistence may run.
///
/// Recovery owns mutation-id replay and validation only. It never inspects Git
/// history or coordinates Git locks; ``VaultVersioning`` is the sole boundary
/// for deciding whether and how a vault snapshot is recorded.
struct VaultMutationRecovery: Sendable {
    /// Outcome of checking durable state for the requested mutation identifier.
    enum Preflight: Sendable {
        /// No receipt prevents persistence.
        case proceed
        /// Replay or snapshot recovery produced the public result.
        case result(FileOperationOutput)
    }

    private let receipts: MutationReceiptStore
    private let versioning: any VaultVersioning
    private let audit: AuditLogger

    /// Creates recovery orchestration for one vault's receipt and versioning boundaries.
    init(
        receipts: MutationReceiptStore,
        versioning: any VaultVersioning,
        audit: AuditLogger
    ) {
        self.receipts = receipts
        self.versioning = versioning
        self.audit = audit
    }

    /// Clears safe pre-persistence state, replays completion, or retries snapshotting.
    func preflight(
        plan: VaultMutationPlan,
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint
    ) async throws -> Preflight {
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
            try await receipts.updatingReceipt { store in
                try store.clearPrePersistenceIntent(
                    identifier: identifier,
                    fingerprint: fingerprint
                )
            }
            return .proceed
        case .prePersistenceWithEvidence, .persistenceStarted:
            throw VaultMutationExecutor.ExecutionError
                .priorAttemptOutcomeUnknown(identifier)
        case .failedAfterPersistence(let output, let recoveryEvidence, let failure):
            guard let output,
                  output.metadata?.mutationID == identifier else {
                throw VaultMutationExecutor.ExecutionError.priorAttemptFailed(
                    identifier,
                    underlying: failure
                )
            }
            return .result(try await recoverSnapshot(
                plan: plan,
                identifier: identifier,
                fingerprint: fingerprint,
                output: output,
                recoveryEvidence: recoveryEvidence
            ))
        }
    }

    /// Validates persisted state, asks the versioning boundary to snapshot it, and finalizes replay.
    ///
    /// Recording is intentionally idempotent: another agent may already have
    /// snapshotted these bytes together with other note changes. In that case the
    /// versioning boundary reports success with no new commit, and recovery can
    /// still finalize this mutation's receipt.
    private func recoverSnapshot(
        plan: VaultMutationPlan,
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint,
        output: FileOperationOutput,
        recoveryEvidence: VaultMutationRecoveryEvidence?
    ) async throws -> FileOperationOutput {
        do {
            try validateRecoveryState(
                plan: plan,
                output: output,
                recoveryEvidence: recoveryEvidence,
                identifier: identifier
            )
            try await Task.detached {
                try await versioning.recordSnapshot()
            }.value
        } catch let error as VaultMutationExecutor.ExecutionError {
            throw error
        } catch {
            let failure = VaultMutationFailureText.bounded(error)
            do {
                try await receipts.updatingReceipt { store in
                    try store.savePostPersistenceFailure(
                        identifier: identifier,
                        fingerprint: fingerprint,
                        output: output,
                        recoveryEvidence: recoveryEvidence,
                        failure: failure
                    )
                }
            } catch {
                await audit.log(
                    operation: VaultOperation(plan.kind.fileOperation),
                    path: plan.path,
                    details: "\(plan.auditDetails); recovery state persistence failed: \(error)"
                )
                throw VaultMutationExecutor.ExecutionError
                    .recoveryStatePersistenceFailed(
                        path: plan.path,
                        underlying: "snapshot failure: \(failure); receipt failure: \(error)"
                    )
            }
            await audit.log(
                operation: VaultOperation(plan.kind.fileOperation),
                path: plan.path,
                details: "\(plan.auditDetails); recovery snapshot failed: \(failure)"
            )
            throw VaultMutationExecutor.ExecutionError.snapshotFailed(
                path: plan.path,
                mutationID: plan.mutationID,
                underlying: failure
            )
        }

        await audit.log(
            operation: VaultOperation(plan.kind.fileOperation),
            path: plan.path,
            details: "\(plan.auditDetails); recovered vault snapshot after prior failure"
        )
        do {
            try await receipts.updatingReceipt { store in
                try store.save(
                    identifier: identifier,
                    fingerprint: fingerprint,
                    output: output
                )
            }
        } catch {
            throw VaultMutationExecutor.ExecutionError.receiptFinalizationFailed(
                path: plan.path,
                underlying: "\(error)"
            )
        }
        guard let metadata = output.metadata else {
            throw MutationReceiptStore.ReceiptError.corrupt(identifier)
        }
        return output.withMetadata(metadata.markingReplayed())
    }

    /// Confirms snapshot recovery still describes the persisted vault state.
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
                try PersistedFileSecurityPolicy.validate(
                    data,
                    format: plan.format,
                    path: plan.path
                )
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
