import Foundation

/// One-call recursive notes-directory moves with Git and durable retry semantics.
actor VaultDirectoryMoveService: DirectoryMoveService {
    enum ExecutionError: Error, CustomStringConvertible, Sendable {
        case gitCommitFailed(MutationID, String)
        case receiptFinalizationFailed(String)

        var description: String {
            switch self {
            case .gitCommitFailed(let identifier, let detail):
                "Directory moved, but its Git commit failed: \(detail). Retry this exact request with mutation_id \(identifier)"
            case .receiptFinalizationFailed(let detail):
                "Directory and Git changed, but the retry receipt could not be finalized: \(detail)"
            }
        }
    }

    private enum Preflight {
        case proceed
        case result(FileOperationOutput)
    }

    private struct ValidatedMove: Sendable {
        let identity: DirectoryTreeStore.Identity
        let destinationManifest: DirectoryMoveSecurityPreflight.Manifest
    }

    private let vaultPath: String
    private let store: DirectoryTreeStore
    private let git: GitRepository
    private let audit: AuditLogger
    private let processMutationLock: POSIXAdvisoryFileLock
    private let receipts: MutationReceiptStore
    private let operations: VaultOperationCoordinator
    private let readOnly: Bool

    init(
        vaultPath: String,
        git: GitRepository,
        audit: AuditLogger,
        processMutationLock: POSIXAdvisoryFileLock,
        receipts: MutationReceiptStore,
        operations: VaultOperationCoordinator,
        readOnly: Bool
    ) {
        self.vaultPath = vaultPath
        self.store = DirectoryTreeStore(vaultPath: vaultPath)
        self.git = git
        self.audit = audit
        self.processMutationLock = processMutationLock
        self.receipts = receipts
        self.operations = operations
        self.readOnly = readOnly
    }

    func move(_ request: MoveDirectoryRequest) async throws -> FileOperationOutput {
        guard !readOnly else { throw FileRoutingError.readOnly }
        let source = try NotesDirectoryTarget.resolve(
            path: request.sourcePath,
            vaultPath: vaultPath
        )
        let destination = try NotesDirectoryTarget.resolve(
            path: request.destinationPath,
            vaultPath: vaultPath
        )
        let sourceIdentity = Self.pathIdentity(source.relativePath)
        let destinationIdentity = Self.pathIdentity(destination.relativePath)
        guard sourceIdentity != destinationIdentity else {
            throw DirectoryMoveError.destinationExists(destination.relativePath)
        }
        guard !destinationIdentity.hasPrefix(sourceIdentity + "/") else {
            throw DirectoryMoveError.destinationInsideSource
        }

        let canonicalRequest = MoveDirectoryRequest(
            mutationID: request.mutationID,
            sourcePath: source.relativePath,
            destinationPath: destination.relativePath
        )
        let fingerprint = try MutationRequestFingerprint.make(
            operationIdentifier: MoveDirectoryRequest.operationIdentifier,
            request: canonicalRequest
        )
        let operations = self.operations
        return try await operations.withTreeWrite {
            try await self.execute(
                canonicalRequest,
                source: source,
                destination: destination,
                fingerprint: fingerprint
            )
        }
    }

    private nonisolated static func pathIdentity(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func execute(
        _ request: MoveDirectoryRequest,
        source: NotesDirectoryTarget,
        destination: NotesDirectoryTarget,
        fingerprint: MutationRequestFingerprint
    ) async throws -> FileOperationOutput {
        let identifier = request.mutationID
        return try await receipts.withIdentityLock(identifier) {
            try await self.processMutationLock.withLock(.exclusive) {
                try Task.checkCancellation()
                let preflight = try await self.preflight(
                    request,
                    source: source,
                    destination: destination,
                    fingerprint: fingerprint
                )
                if case .result(let output) = preflight { return output }

                let validated = try self.validateFreshMove(
                    source: source,
                    destination: destination
                )
                try self.receipts.saveInProgress(
                    identifier: identifier,
                    fingerprint: fingerprint,
                    recoveryEvidence: .directoryMoveIntent(
                        sourcePath: source.relativePath,
                        destinationPath: destination.relativePath,
                        identity: validated.identity,
                        summary: validated.destinationManifest.summary
                    )
                )
                try self.receipts.saveActiveTransaction(
                    identifier: identifier,
                    fingerprint: fingerprint
                )
                return try await Task.detached {
                    try await self.performCritical(
                        request,
                        source: source,
                        destination: destination,
                        fingerprint: fingerprint,
                        expectedIdentity: validated.identity,
                        destinationManifest: validated.destinationManifest
                    )
                }.value
            }
        }
    }

    private func preflight(
        _ request: MoveDirectoryRequest,
        source: NotesDirectoryTarget,
        destination: NotesDirectoryTarget,
        fingerprint: MutationRequestFingerprint
    ) async throws -> Preflight {
        let identifier = request.mutationID
        let lookup = try receipts.replay(
            identifier: identifier,
            fingerprint: fingerprint
        )
        let active = try receipts.activeTransaction()
        guard let lookup else {
            guard active == nil else {
                throw DirectoryMoveError.recoveryRequired(active!.identifier)
            }
            return .proceed
        }
        switch lookup {
        case .completed(let output):
            _ = try receipts.clearMatchingActiveTransaction(
                identifier: identifier,
                fingerprint: fingerprint
            )
            return .result(output)
        case .failedAfterPersistence(let savedOutput, let evidence, _):
            guard let active,
                  active.identifier == identifier,
                  active.fingerprint == fingerprint,
                  let savedOutput else {
                throw DirectoryMoveError.recoveryRequired(identifier)
            }
            let validated = try validatePersistedMove(
                source: source,
                destination: destination,
                evidence: evidence,
                identifier: identifier
            )
            return .result(try await finishCommit(
                request,
                output: savedOutput,
                identity: validated.identity,
                destinationManifest: validated.destinationManifest,
                fingerprint: fingerprint,
                active: active,
                replayed: true
            ))
        case .prePersistenceWithEvidence(let evidence):
            guard case .directoryMoveIntent(
                let sourcePath,
                let destinationPath,
                let expectedIdentity,
                let expectedSummary
            ) = evidence,
                  sourcePath == source.relativePath,
                  destinationPath == destination.relativePath else {
                throw DirectoryMoveError.recoveryRequired(identifier)
            }
            guard let active else {
                // Persistence cannot begin until the active marker is durable.
                // A crash between the two intent writes is therefore safe to
                // restart after removing the orphaned first record.
                try receipts.clearPrePersistenceIntent(
                    identifier: identifier,
                    fingerprint: fingerprint
                )
                return .proceed
            }
            guard active.identifier == identifier,
                  active.fingerprint == fingerprint else {
                throw DirectoryMoveError.recoveryRequired(active.identifier)
            }
            let sourceState = try store.state(of: source)
            let destinationState = try store.state(of: destination)
            switch (sourceState, destinationState) {
            case (.directory(let identity), .missing) where identity == expectedIdentity:
                try receipts.clearActiveTransaction(active)
                try receipts.clearPrePersistenceIntent(
                    identifier: identifier,
                    fingerprint: fingerprint
                )
                return .proceed
            case (.missing, .directory(let identity)) where identity == expectedIdentity:
                let manifest = try validatedRecoveryManifest(
                    destination,
                    expectedSummary: expectedSummary,
                    identifier: identifier
                )
                let output = makeOutput(request)
                return .result(try await finishCommit(
                    request,
                    output: output,
                    identity: identity,
                    destinationManifest: manifest,
                    fingerprint: fingerprint,
                    active: active,
                    replayed: true
                ))
            default:
                throw DirectoryMoveError.recoveryRequired(identifier)
            }
        case .prePersistence, .outcomeUnknown:
            throw DirectoryMoveError.recoveryRequired(identifier)
        }
    }

    private nonisolated func validateFreshMove(
        source: NotesDirectoryTarget,
        destination: NotesDirectoryTarget
    ) throws -> ValidatedMove {
        let identity: DirectoryTreeStore.Identity
        switch try store.state(of: source) {
        case .missing: throw DirectoryMoveError.sourceNotFound(source.relativePath)
        case .other: throw DirectoryMoveError.sourceNotDirectory(source.relativePath)
        case .directory(let value): identity = value
        }
        guard try store.state(of: destination) == .missing else {
            throw DirectoryMoveError.destinationExists(destination.relativePath)
        }
        let sourceManifest = try DirectoryMoveSecurityPreflight.validate(source)
        return ValidatedMove(
            identity: identity,
            destinationManifest: try sourceManifest.rebased(
                to: destination.relativePath
            )
        )
    }

    private nonisolated func makeOutput(
        _ request: MoveDirectoryRequest
    ) -> FileOperationOutput {
        FileOperationOutput.text(
            "Moved \(request.sourcePath) → \(request.destinationPath)"
        ).withMetadata(FileOperationMetadata(
            path: request.destinationPath,
            sourcePath: request.sourcePath,
            area: .notes,
            revision: nil,
            mutationID: request.mutationID,
            replayed: false
        ))
    }

    private func performCritical(
        _ request: MoveDirectoryRequest,
        source: NotesDirectoryTarget,
        destination: NotesDirectoryTarget,
        fingerprint: MutationRequestFingerprint,
        expectedIdentity: DirectoryTreeStore.Identity,
        destinationManifest: DirectoryMoveSecurityPreflight.Manifest
    ) async throws -> FileOperationOutput {
        let identity: DirectoryTreeStore.Identity
        do {
            identity = try store.move(
                source: source,
                destination: destination,
                expectedIdentity: expectedIdentity
            )
        } catch {
            let active = MutationReceiptStore.ActiveTransaction(
                identifier: request.mutationID,
                fingerprint: fingerprint
            )
            if (try? store.state(of: source)) == .directory(expectedIdentity),
               (try? store.state(of: destination)) == .missing {
                try? receipts.clearActiveTransaction(active)
                try? receipts.clearPrePersistenceIntent(
                    identifier: request.mutationID,
                    fingerprint: fingerprint
                )
            }
            await audit.log(
                operation: .move,
                path: request.sourcePath,
                details: "destination=\(request.destinationPath); persistence failed: \(error)"
            )
            throw error
        }
        let active = MutationReceiptStore.ActiveTransaction(
            identifier: request.mutationID,
            fingerprint: fingerprint
        )
        return try await finishCommit(
            request,
            output: makeOutput(request),
            identity: identity,
            destinationManifest: destinationManifest,
            fingerprint: fingerprint,
            active: active,
            replayed: false
        )
    }

    private func finishCommit(
        _ request: MoveDirectoryRequest,
        output: FileOperationOutput,
        identity: DirectoryTreeStore.Identity,
        destinationManifest: DirectoryMoveSecurityPreflight.Manifest,
        fingerprint: MutationRequestFingerprint,
        active: MutationReceiptStore.ActiveTransaction,
        replayed: Bool
    ) async throws -> FileOperationOutput {
        let alreadyCommitted: Bool
        if replayed {
            alreadyCommitted = try await git.containsMutationCommit(
                identifier: request.mutationID,
                fingerprint: fingerprint
            )
        } else {
            alreadyCommitted = false
        }
        if !alreadyCommitted {
            do {
                try await git.commitMove(
                    sourcePath: request.sourcePath,
                    destinationPath: request.destinationPath,
                    manifest: destinationManifest,
                    message: "[SecondBrainMCP] Moved directory: \(request.sourcePath) to \(request.destinationPath)",
                    identity: GitMutationIdentity(
                        identifier: request.mutationID,
                        fingerprint: fingerprint
                    )
                )
            } catch {
                let failure = VaultMutationFailureText.bounded(error)
                try receipts.savePostPersistenceFailure(
                    identifier: request.mutationID,
                    fingerprint: fingerprint,
                    output: output,
                    recoveryEvidence: .movedDirectory(
                        sourcePath: request.sourcePath,
                        destinationPath: request.destinationPath,
                        identity: identity,
                        summary: destinationManifest.summary
                    ),
                    failure: failure
                )
                await audit.log(
                    operation: .move,
                    path: request.sourcePath,
                    details: "destination=\(request.destinationPath); git failed: \(failure)"
                )
                throw ExecutionError.gitCommitFailed(request.mutationID, failure)
            }
        } else {
            try await git.reconcileCommittedMove(
                sourcePath: request.sourcePath,
                destinationPath: request.destinationPath
            )
        }

        await audit.log(
            operation: .move,
            path: request.sourcePath,
            details: "destination=\(request.destinationPath); mutation_id=\(request.mutationID.rawValue)"
        )
        do {
            try receipts.save(
                identifier: request.mutationID,
                fingerprint: fingerprint,
                output: output
            )
            try receipts.clearActiveTransaction(active)
        } catch {
            throw ExecutionError.receiptFinalizationFailed("\(error)")
        }
        guard replayed, let metadata = output.metadata else { return output }
        return output.withMetadata(metadata.markingReplayed())
    }

    private func validatePersistedMove(
        source: NotesDirectoryTarget,
        destination: NotesDirectoryTarget,
        evidence: VaultMutationRecoveryEvidence?,
        identifier: MutationID
    ) throws -> ValidatedMove {
        guard case .movedDirectory(
            let sourcePath,
            let destinationPath,
            let expectedIdentity,
            let expectedSummary
        ) = evidence,
              sourcePath == source.relativePath,
              destinationPath == destination.relativePath,
              try store.state(of: source) == .missing,
              case .directory(let actualIdentity) = try store.state(of: destination),
              actualIdentity == expectedIdentity else {
            throw DirectoryMoveError.recoveryRequired(identifier)
        }
        return ValidatedMove(
            identity: expectedIdentity,
            destinationManifest: try validatedRecoveryManifest(
                destination,
                expectedSummary: expectedSummary,
                identifier: identifier
            )
        )
    }

    private func validatedRecoveryManifest(
        _ destination: NotesDirectoryTarget,
        expectedSummary: DirectoryMoveSecurityPreflight.Manifest.Summary,
        identifier: MutationID
    ) throws -> DirectoryMoveSecurityPreflight.Manifest {
        let manifest = try DirectoryMoveSecurityPreflight.validate(destination)
        guard manifest.summary == expectedSummary else {
            throw DirectoryMoveError.recoveryRequired(identifier)
        }
        return manifest
    }
}
