import Foundation

/// Moves one supported file or one complete notes subtree under the global mutation lease.
actor VaultPathMoveService: PathMoveService {
    private let vaultPath: String
    private let tree: PathTreeStore
    private let fileStore: VaultCRUDStore
    private let supportedFileFormats: Set<FileFormat>
    private let mutations: VaultMutationExecutor
    private let access: any VaultAccessCoordinating
    private let readOnly: Bool

    init(
        vaultPath: String,
        supportedFileFormats: Set<FileFormat>,
        versioning: any VaultVersioning,
        access: any VaultAccessCoordinating,
        readOnly: Bool
    ) {
        self.vaultPath = vaultPath
        self.tree = PathTreeStore(vaultPath: vaultPath)
        self.fileStore = VaultCRUDStore(vaultPath: vaultPath)
        self.supportedFileFormats = supportedFileFormats
        self.mutations = VaultMutationExecutor(versioning: versioning)
        self.access = access
        self.readOnly = readOnly
    }

    func move(_ request: MovePathRequest) async throws -> FileOperationOutput {
        guard !readOnly else { throw FileRoutingError.readOnly }
        return try await access.withMutation {
            let prepared = try await self.mutations.prepare {
                switch request {
                case .file(
                    let sourcePath,
                    let destinationPath,
                    let format,
                    let expectedRevision
                ):
                    return try await self.prepareFileMove(
                        sourcePath: sourcePath,
                        destinationPath: destinationPath,
                        format: format,
                        expectedRevision: expectedRevision
                    )
                case .directory(let sourcePath, let destinationPath):
                    return try await self.prepareDirectoryMove(
                        sourcePath: sourcePath,
                        destinationPath: destinationPath
                    )
                }
            }
            return try await self.mutations.execute(prepared)
        }
    }

    private func prepareFileMove(
        sourcePath: String,
        destinationPath: String,
        format: FileFormat,
        expectedRevision: FileRevision
    ) async throws -> PreparedVaultMutation {
        guard sourcePath.utf8.count <= PathMoveRequestLimits.maximumPathBytes,
              destinationPath.utf8.count <= PathMoveRequestLimits.maximumPathBytes else {
            throw PathMoveError.pathTooLong
        }
        guard supportedFileFormats.contains(format) else {
            throw FileRoutingError.operationNotSupported(
                format: format,
                operation: .read,
                area: .notes
            )
        }
        let source = try WritableFileTarget.resolve(
            path: sourcePath,
            format: format,
            vaultPath: vaultPath
        )
        let destination = try WritableFileTarget.resolve(
            path: destinationPath,
            format: format,
            vaultPath: vaultPath
        )
        guard Self.pathIdentity(source.relativePath)
            != Self.pathIdentity(destination.relativePath) else {
            throw PathMoveError.sourceAndDestinationAreSame
        }

        let snapshot = try await fileStore.snapshot(source.readable)
        guard snapshot.revision == expectedRevision else {
            throw FileRoutingError.revisionConflict(source.relativePath)
        }
        try PersistedFileSecurityPolicy.validateGitCandidate(
            snapshot.data,
            format: format,
            path: source.relativePath
        )
        try Task.checkCancellation()

        let tree = self.tree
        return PreparedVaultMutation(
            requiresSnapshot: true,
            snapshotPaths: [source.relativePath, destination.relativePath],
            perform: {
                let movedRevision = try tree.moveFile(
                    source: source,
                    destination: destination,
                    expectedRevision: expectedRevision
                )
                return FileOperationOutput.text(
                    "Moved \(source.relativePath) → \(destination.relativePath)"
                ).withMetadata(FileOperationMetadata(
                    path: destination.relativePath,
                    sourcePath: source.relativePath,
                    area: .notes,
                    revision: movedRevision
                ))
            }
        )
    }

    private func prepareDirectoryMove(
        sourcePath: String,
        destinationPath: String
    ) async throws -> PreparedVaultMutation {
        let canonicalSource = try NotesDirectoryTarget.canonicalize(path: sourcePath)
        let canonicalDestination = try NotesDirectoryTarget.canonicalize(path: destinationPath)
        let sourceIdentity = Self.pathIdentity(canonicalSource)
        let destinationIdentity = Self.pathIdentity(canonicalDestination)
        guard sourceIdentity != destinationIdentity else {
            throw DirectoryMoveError.sourceAndDestinationAreSame
        }
        guard !destinationIdentity.hasPrefix(sourceIdentity + "/") else {
            throw DirectoryMoveError.destinationInsideSource
        }

        let source = try NotesDirectoryTarget.resolve(
            path: canonicalSource,
            vaultPath: vaultPath
        )
        let destination = try NotesDirectoryTarget.resolve(
            path: canonicalDestination,
            vaultPath: vaultPath
        )
        let identity: PathTreeStore.Identity
        switch try tree.state(of: source) {
        case .missing:
            throw DirectoryMoveError.sourceNotFound(source.relativePath)
        case .other:
            throw DirectoryMoveError.sourceNotDirectory(source.relativePath)
        case .directory(let value):
            identity = value
        }
        guard try tree.state(of: destination) == .missing else {
            throw DirectoryMoveError.destinationExists(destination.relativePath)
        }

        _ = try DirectoryMoveSecurityPreflight.validate(source)
            .rebased(to: destination.relativePath)
        try Task.checkCancellation()
        let tree = self.tree
        return PreparedVaultMutation(requiresSnapshot: true, perform: {
            _ = try tree.moveDirectory(
                source: source,
                destination: destination,
                expectedIdentity: identity
            )
            return FileOperationOutput.text(
                "Moved \(source.relativePath) → \(destination.relativePath)"
            ).withMetadata(FileOperationMetadata(
                path: destination.relativePath,
                sourcePath: source.relativePath,
                area: .notes,
                revision: nil
            ))
        })
    }

    private nonisolated static func pathIdentity(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// Safe caller-facing failures specific to regular-file moves.
enum PathMoveError: Error, CustomStringConvertible, CallerSafeError, Sendable {
    case pathTooLong
    case invalidFilePath(String)
    case sourceNotFound(String)
    case sourceNotFile(String)
    case sourceChanged(String)
    case destinationExists(String)
    case sourceAndDestinationAreSame
    case unsafeFilesystemOperation(String)

    var callerSafeDescription: String {
        description
    }

    var description: String {
        switch self {
        case .pathTooLong:
            "Path exceeds the UTF-8 byte limit"
        case .invalidFilePath(let path):
            "Invalid notes file path: \(path)"
        case .sourceNotFound(let path):
            "Source file does not exist: \(path)"
        case .sourceNotFile(let path):
            "Source is not a regular file: \(path)"
        case .sourceChanged(let path):
            "Source file changed while the move was being prepared: \(path)"
        case .destinationExists(let path):
            "Destination already exists: \(path)"
        case .sourceAndDestinationAreSame:
            "Source and destination resolve to the same path"
        case .unsafeFilesystemOperation(let operation):
            "File move could not safely \(operation)"
        }
    }
}
