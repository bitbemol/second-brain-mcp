import Foundation

/// Routes generic file CRUD through format handlers, atomic storage, one global
/// vault access boundary, and the awaited versioning chain.
actor VaultFileService: FileCRUDService {
    private let catalog: FileFormatCatalog
    private let vaultPath: String
    private let store: VaultCRUDStore
    private let mutations: VaultMutationExecutor
    private let access: any VaultAccessCoordinating
    private let readOnly: Bool

    init(
        vaultPath: String,
        catalog: FileFormatCatalog,
        store: VaultCRUDStore,
        mutations: VaultMutationExecutor,
        access: any VaultAccessCoordinating,
        readOnly: Bool = false
    ) {
        self.vaultPath = vaultPath
        self.catalog = catalog
        self.store = store
        self.mutations = mutations
        self.access = access
        self.readOnly = readOnly
    }

    func create(_ request: CreateFileRequest) async throws -> FileOperationOutput {
        try requireMutationPermission()
        return try await access.withMutation {
            let target = try self.resolveWritableTarget(
                path: request.path,
                format: request.format
            )
            try FileMutationResourcePreflight.validate(request)
            let binding = try self.catalog.createBinding(
                for: request.format,
                in: target.area
            )
            try await self.store.requireAbsent(target)
            let prepared = try await binding.execute(request, target)
            try SensitiveContentPolicy.validate(
                prepared.data,
                format: target.format,
                path: target.relativePath
            )
            try await self.store.requireAbsent(target)
            let revision = FileSnapshot(
                data: prepared.data,
                modifiedDate: nil
            ).revision
            let output = prepared.output.withMetadata(FileOperationMetadata(
                path: target.relativePath,
                area: target.area,
                revision: revision
            ))
            return try await self.mutations.execute(PreparedVaultMutation(
                requiresSnapshot: true,
                perform: {
                    _ = try await self.store.create(
                        target: target,
                        data: prepared.data
                    )
                    return output
                }
            ))
        }
    }

    func read(_ request: ReadFileRequest) async throws -> FileOperationOutput {
        try await access.withRead {
            let target = try ReadableFileTarget.resolve(
                path: request.path,
                format: request.format,
                vaultPath: self.vaultPath
            )
            let binding = try self.catalog.readBinding(
                for: request.format,
                in: target.area
            )
            if target.area == .notes {
                let snapshot = try await self.store.snapshot(target)
                let output = try await binding.execute(request, target)
                let confirmed = try await self.store.snapshot(target)
                guard confirmed.revision == snapshot.revision else {
                    throw FileRoutingError.changedDuringRead(target.relativePath)
                }
                return output.withMetadata(FileOperationMetadata(
                    path: target.relativePath,
                    area: target.area,
                    revision: snapshot.revision
                ))
            }
            return try await binding.execute(request, target).withMetadata(
                FileOperationMetadata(
                    path: target.relativePath,
                    area: target.area,
                    revision: nil
                )
            )
        }
    }

    func update(_ request: UpdateFileRequest) async throws -> FileOperationOutput {
        try requireMutationPermission()
        return try await access.withMutation {
            let target = try self.resolveWritableTarget(
                path: request.path,
                format: request.format
            )
            try FileMutationResourcePreflight.validate(request)
            let binding = try self.catalog.updateBinding(
                for: request.format,
                in: target.area
            )
            let snapshot = try await self.store.snapshot(target.readable)
            guard snapshot.revision == request.expectedRevision else {
                throw FileRoutingError.revisionConflict(target.relativePath)
            }
            let prepared = try await binding.execute(request, target, snapshot)
            try SensitiveContentPolicy.validate(
                prepared.data,
                format: target.format,
                path: target.relativePath
            )
            let noChanges = prepared.data == snapshot.data
            let revision = noChanges
                ? snapshot.revision
                : FileSnapshot(data: prepared.data, modifiedDate: nil).revision
            let output = (noChanges
                ? FileOperationOutput.text("No changes: \(target.relativePath)")
                : prepared.output
            ).withMetadata(FileOperationMetadata(
                path: target.relativePath,
                area: target.area,
                revision: revision
            ))
            return try await self.mutations.execute(PreparedVaultMutation(
                requiresSnapshot: !noChanges,
                perform: {
                    guard !noChanges else { return output }
                    do {
                        _ = try await self.store.replace(
                            target: target,
                            data: prepared.data,
                            expectedRevision: request.expectedRevision
                        )
                    } catch VaultCRUDStore.StoreError.changedSinceRead {
                        throw FileRoutingError.revisionConflict(target.relativePath)
                    }
                    return output
                }
            ))
        }
    }

    func delete(_ request: DeleteFileRequest) async throws -> FileOperationOutput {
        try requireMutationPermission()
        return try await access.withMutation {
            let target = try self.resolveWritableTarget(
                path: request.path,
                format: request.format
            )
            let binding = try self.catalog.deleteBinding(
                for: request.format,
                in: target.area
            )
            let snapshot = try await self.store.snapshot(target.readable)
            guard snapshot.revision == request.expectedRevision else {
                throw FileRoutingError.revisionConflict(target.relativePath)
            }
            try await binding.execute(request, target)
            return try await self.mutations.execute(PreparedVaultMutation(
                requiresSnapshot: true,
                perform: {
                    let deletion: (trashPath: String, deletedRevision: FileRevision)
                    do {
                        deletion = try await self.store.softDelete(
                            target: target,
                            expectedRevision: request.expectedRevision
                        )
                    } catch VaultCRUDStore.StoreError.changedSinceRead {
                        throw FileRoutingError.revisionConflict(target.relativePath)
                    }
                    return FileOperationOutput.text(
                        "Deleted \(target.relativePath) → \(deletion.trashPath)"
                    ).withMetadata(FileOperationMetadata(
                        path: target.relativePath,
                        area: target.area,
                        revision: nil
                    ))
                }
            ))
        }
    }

    private nonisolated func resolveWritableTarget(
        path: String,
        format: FileFormat
    ) throws -> WritableFileTarget {
        try WritableFileTarget.resolve(
            path: path,
            format: format,
            vaultPath: vaultPath
        )
    }

    private func requireMutationPermission() throws {
        guard !readOnly else { throw FileRoutingError.readOnly }
    }
}
