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

    private let vaultPath: String
    private let store: DirectoryTreeStore
    private let git: GitRepository
    private let audit: AuditLogger
    private let processMutationLock: POSIXAdvisoryFileLock
    private let receipts: MutationReceiptStore
    private let operations: VaultOperationCoordinator
    private let readOnly: Bool
    private let gate = AsyncExclusiveGate()

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
            operationIdentifier: DirectoryMoveToolDefinition.name,
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
            try await self.gate.withPermit {
                try await self.processMutationLock.withLock(.exclusive) {
                    try Task.checkCancellation()
                    let preflight = try await self.preflight(
                        request,
                        source: source,
                        destination: destination,
                        fingerprint: fingerprint
                    )
                    if case .result(let output) = preflight { return output }

                    let sourceIdentity = try self.validateFreshMove(
                        source: source,
                        destination: destination
                    )
                    try self.receipts.saveInProgress(
                        identifier: identifier,
                        fingerprint: fingerprint,
                        recoveryEvidence: .directoryMoveIntent(
                            sourcePath: source.relativePath,
                            destinationPath: destination.relativePath,
                            identity: sourceIdentity
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
                            expectedIdentity: sourceIdentity
                        )
                    }.value
                }
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
            return .result(output)
        case .failedAfterPersistence(let savedOutput, let evidence, _):
            guard let active,
                  active.identifier == identifier,
                  active.fingerprint == fingerprint,
                  let savedOutput else {
                throw DirectoryMoveError.recoveryRequired(identifier)
            }
            let identity = try validatePersistedMove(
                source: source,
                destination: destination,
                evidence: evidence,
                identifier: identifier
            )
            return .result(try await finishCommit(
                request,
                output: savedOutput,
                identity: identity,
                fingerprint: fingerprint,
                active: active,
                replayed: true
            ))
        case .prePersistenceWithEvidence(let evidence):
            guard let active,
                  active.identifier == identifier,
                  active.fingerprint == fingerprint else {
                throw DirectoryMoveError.recoveryRequired(identifier)
            }
            guard case .directoryMoveIntent(
                let sourcePath,
                let destinationPath,
                let expectedIdentity
            ) = evidence,
                  sourcePath == source.relativePath,
                  destinationPath == destination.relativePath else {
                throw DirectoryMoveError.recoveryRequired(identifier)
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
                let output = makeOutput(request)
                return .result(try await finishCommit(
                    request,
                    output: output,
                    identity: identity,
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
    ) throws -> DirectoryTreeStore.Identity {
        let identity: DirectoryTreeStore.Identity
        switch try store.state(of: source) {
        case .missing: throw DirectoryMoveError.sourceNotFound(source.relativePath)
        case .other: throw DirectoryMoveError.sourceNotDirectory(source.relativePath)
        case .directory(let value): identity = value
        }
        guard try store.state(of: destination) == .missing else {
            throw DirectoryMoveError.destinationExists(destination.relativePath)
        }
        try DirectoryMoveSecurityPreflight.validate(source)
        return identity
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
        expectedIdentity: DirectoryTreeStore.Identity
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
            fingerprint: fingerprint,
            active: active,
            replayed: false
        )
    }

    private func finishCommit(
        _ request: MoveDirectoryRequest,
        output: FileOperationOutput,
        identity: DirectoryTreeStore.Identity,
        fingerprint: MutationRequestFingerprint,
        active: MutationReceiptStore.ActiveTransaction,
        replayed: Bool
    ) async throws -> FileOperationOutput {
        let alreadyCommitted = try await git.containsMutationCommit(
            identifier: request.mutationID,
            paths: [request.sourcePath, request.destinationPath]
        )
        if !alreadyCommitted {
            do {
                try await git.commitMove(
                    sourcePath: request.sourcePath,
                    destinationPath: request.destinationPath,
                    message: "[SecondBrainMCP] Moved directory: \(request.sourcePath) to \(request.destinationPath) [mutation \(request.mutationID.rawValue)]"
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
                        identity: identity
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
    ) throws -> DirectoryTreeStore.Identity {
        guard case .movedDirectory(
            let sourcePath,
            let destinationPath,
            let expectedIdentity
        ) = evidence,
              sourcePath == source.relativePath,
              destinationPath == destination.relativePath,
              try store.state(of: source) == .missing,
              case .directory(let actualIdentity) = try store.state(of: destination),
              actualIdentity == expectedIdentity else {
            throw DirectoryMoveError.recoveryRequired(identifier)
        }
        return expectedIdentity
    }
}
