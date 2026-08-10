import Foundation

/// Moves complete notes subtrees under the vault's global mutation lease.
actor VaultDirectoryMoveService: DirectoryMoveService {
    private let vaultPath: String
    private let store: DirectoryTreeStore
    private let versioning: any VaultVersioning
    private let access: any VaultAccessCoordinating
    private let readOnly: Bool

    init(
        vaultPath: String,
        versioning: any VaultVersioning,
        access: any VaultAccessCoordinating,
        readOnly: Bool
    ) {
        self.vaultPath = vaultPath
        self.store = DirectoryTreeStore(vaultPath: vaultPath)
        self.versioning = versioning
        self.access = access
        self.readOnly = readOnly
    }

    func move(_ request: MoveDirectoryRequest) async throws -> FileOperationOutput {
        guard !readOnly else { throw FileRoutingError.readOnly }
        return try await access.withMutation {
            let sourcePath = try NotesDirectoryTarget.canonicalize(
                path: request.sourcePath
            )
            let destinationPath = try NotesDirectoryTarget.canonicalize(
                path: request.destinationPath
            )
            let sourceIdentity = Self.pathIdentity(sourcePath)
            let destinationIdentity = Self.pathIdentity(destinationPath)
            guard sourceIdentity != destinationIdentity else {
                throw DirectoryMoveError.sourceAndDestinationAreSame
            }
            guard !destinationIdentity.hasPrefix(sourceIdentity + "/") else {
                throw DirectoryMoveError.destinationInsideSource
            }

            let source = try NotesDirectoryTarget.resolve(
                path: sourcePath,
                vaultPath: self.vaultPath
            )
            let destination = try NotesDirectoryTarget.resolve(
                path: destinationPath,
                vaultPath: self.vaultPath
            )
            let identity: DirectoryTreeStore.Identity
            switch try self.store.state(of: source) {
            case .missing:
                throw DirectoryMoveError.sourceNotFound(source.relativePath)
            case .other:
                throw DirectoryMoveError.sourceNotDirectory(source.relativePath)
            case .directory(let value):
                identity = value
            }
            guard try self.store.state(of: destination) == .missing else {
                throw DirectoryMoveError.destinationExists(destination.relativePath)
            }

            _ = try DirectoryMoveSecurityPreflight.validate(source)
                .rebased(to: destination.relativePath)
            try Task.checkCancellation()
            let store = self.store
            let versioning = self.versioning
            return try await Task.detached {
                _ = try store.move(
                    source: source,
                    destination: destination,
                    expectedIdentity: identity
                )
                try await versioning.recordSnapshot()
                return FileOperationOutput.text(
                    "Moved \(source.relativePath) → \(destination.relativePath)"
                ).withMetadata(FileOperationMetadata(
                    path: destination.relativePath,
                    sourcePath: source.relativePath,
                    area: .notes,
                    revision: nil
                ))
            }.value
        }
    }

    private nonisolated static func pathIdentity(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
