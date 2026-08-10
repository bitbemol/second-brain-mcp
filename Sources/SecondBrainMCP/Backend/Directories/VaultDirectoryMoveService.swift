import Foundation

/// Moves note subtrees with durable retry semantics and vault snapshots.
actor VaultDirectoryMoveService: DirectoryMoveService {
    enum ExecutionError: Error, CustomStringConvertible, Sendable {
        case snapshotFailed(MutationID, String)
        case receiptFinalizationFailed(String)

        var description: String {
            switch self {
            case .snapshotFailed(let identifier, let detail):
                "Directory moved, but its vault snapshot failed: \(detail). Retry this exact request with mutation_id \(identifier)"
            case .receiptFinalizationFailed(let detail):
                "Directory and versioning changed, but the retry receipt could not be finalized: \(detail)"
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
    private let versioning: any VaultVersioning
    private let receipts: MutationReceiptStore
    private let operations: VaultOperationCoordinator
    private let readOnly: Bool

    /// Creates a note-tree mover whose snapshots are delegated to the versioning boundary.
    init(
        vaultPath: String,
        versioning: any VaultVersioning,
        receipts: MutationReceiptStore,
        operations: VaultOperationCoordinator,
        readOnly: Bool
    ) {
        self.vaultPath = vaultPath
        self.store = DirectoryTreeStore(vaultPath: vaultPath)
        self.versioning = versioning
        self.receipts = receipts
        self.operations = operations
        self.readOnly = readOnly
    }

    func move(_ request: MoveDirectoryRequest) async throws -> FileOperationOutput {
        guard !readOnly else { throw FileRoutingError.readOnly }
        let sourcePath = try NotesDirectoryTarget.canonicalize(path: request.sourcePath)
        let destinationPath = try NotesDirectoryTarget.canonicalize(path: request.destinationPath)
        let sourceIdentity = Self.pathIdentity(sourcePath)
        let destinationIdentity = Self.pathIdentity(destinationPath)
        guard sourceIdentity != destinationIdentity else {
            throw DirectoryMoveError.sourceAndDestinationAreSame
        }
        guard !destinationIdentity.hasPrefix(sourceIdentity + "/") else {
            throw DirectoryMoveError.destinationInsideSource
        }
        let source = try NotesDirectoryTarget.resolve(path: sourcePath, vaultPath: vaultPath)
        let destination = try NotesDirectoryTarget.resolve(
            path: destinationPath,
            vaultPath: vaultPath
        )

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
            try await self.receipts.updatingReceipt { store in
                try store.saveInProgress(
                    identifier: identifier,
                    fingerprint: fingerprint,
                    recoveryEvidence: .directoryMoveIntent(
                        sourcePath: source.relativePath,
                        destinationPath: destination.relativePath,
                        identity: validated.identity,
                        summary: validated.destinationManifest.summary
                    )
                )
                try store.markPersistenceStarted(
                    identifier: identifier,
                    fingerprint: fingerprint
                )
            }
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

    private func preflight(
        _ request: MoveDirectoryRequest,
        source: NotesDirectoryTarget,
        destination: NotesDirectoryTarget,
        fingerprint: MutationRequestFingerprint
    ) async throws -> Preflight {
        let identifier = request.mutationID
        guard let lookup = try receipts.replay(
            identifier: identifier,
            fingerprint: fingerprint
        ) else {
            return .proceed
        }

        switch lookup {
        case .completed(let output):
            return .result(output)
        case .prePersistence, .prePersistenceWithEvidence:
            try await receipts.updatingReceipt { store in
                try store.clearPrePersistenceIntent(
                    identifier: identifier,
                    fingerprint: fingerprint
                )
            }
            return .proceed
        case .persistenceStarted(let evidence):
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
            let sourceState = try store.state(of: source)
            let destinationState = try store.state(of: destination)
            switch (sourceState, destinationState) {
            case (.directory(let identity), .missing) where identity == expectedIdentity:
                try await receipts.updatingReceipt { store in
                    try store.clearPersistenceStarted(
                        identifier: identifier,
                        fingerprint: fingerprint
                    )
                }
                return .proceed
            case (.missing, .directory(let identity)) where identity == expectedIdentity:
                let manifest = try validatedRecoveryManifest(
                    destination,
                    expectedSummary: expectedSummary,
                    identifier: identifier
                )
                return .result(try await finishSnapshot(
                    request,
                    output: makeOutput(request),
                    identity: identity,
                    destinationManifest: manifest,
                    fingerprint: fingerprint,
                    replayed: true
                ))
            default:
                throw DirectoryMoveError.recoveryRequired(identifier)
            }
        case .failedAfterPersistence(let savedOutput, let evidence, _):
            guard let savedOutput else {
                throw DirectoryMoveError.recoveryRequired(identifier)
            }
            let validated = try validatePersistedMove(
                source: source,
                destination: destination,
                evidence: evidence,
                identifier: identifier
            )
            return .result(try await finishSnapshot(
                request,
                output: savedOutput,
                identity: validated.identity,
                destinationManifest: validated.destinationManifest,
                fingerprint: fingerprint,
                replayed: true
            ))
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
            if (try? store.state(of: source)) == .directory(expectedIdentity),
               (try? store.state(of: destination)) == .missing {
                try? await receipts.updatingReceipt { store in
                    try store.clearPersistenceStarted(
                        identifier: request.mutationID,
                        fingerprint: fingerprint
                    )
                }
            }
            throw error
        }
        return try await finishSnapshot(
            request,
            output: makeOutput(request),
            identity: identity,
            destinationManifest: destinationManifest,
            fingerprint: fingerprint,
            replayed: false
        )
    }

    /// Records the moved note tree through the sole version-control boundary.
    ///
    /// Another agent's snapshot may already include this move or may include other
    /// concurrent note changes with it. Both outcomes are intentional: snapshots
    /// preserve recoverable vault states rather than mutation ownership.
    private func finishSnapshot(
        _ request: MoveDirectoryRequest,
        output: FileOperationOutput,
        identity: DirectoryTreeStore.Identity,
        destinationManifest: DirectoryMoveSecurityPreflight.Manifest,
        fingerprint: MutationRequestFingerprint,
        replayed: Bool
    ) async throws -> FileOperationOutput {
        do {
            try await versioning.recordSnapshot()
        } catch {
            let failure = VaultMutationFailureText.bounded(error)
            try await receipts.updatingReceipt { store in
                try store.savePostPersistenceFailure(
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
            }
            throw ExecutionError.snapshotFailed(request.mutationID, failure)
        }

        do {
            try await receipts.updatingReceipt { store in
                try store.save(
                    identifier: request.mutationID,
                    fingerprint: fingerprint,
                    output: output
                )
            }
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
