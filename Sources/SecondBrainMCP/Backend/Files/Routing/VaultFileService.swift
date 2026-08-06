import Foundation

/// Single backend interface for generic file CRUD. It validates declared format,
/// vault area, extension, and operation policy; delegates format semantics to the
/// selected binding; then delegates prepared mutations to the transaction boundary.
actor VaultFileService: FileCRUDService {
    private let catalog: FileFormatCatalog
    private let vaultPath: String
    private let store: VaultCRUDStore
    private let mutations: VaultMutationExecutor
    private let operations: VaultOperationCoordinator
    private let audit: AuditLogger
    private let readOnly: Bool

    /// Creates the single routed CRUD service.
    ///
    /// - Parameters:
    ///   - vaultPath: Canonical vault root.
    ///   - catalog: Immutable format-operation registrations.
    ///   - store: Sole generic persistence actor.
    ///   - mutations: Serialized persistence, Git, and audit transaction boundary.
    ///   - operations: Fair notes-path coordination shared across processes.
    ///   - audit: Append-only operation log.
    ///   - readOnly: Whether mutation methods must fail before resolving or writing.
    init(
        vaultPath: String,
        catalog: FileFormatCatalog,
        store: VaultCRUDStore,
        mutations: VaultMutationExecutor,
        operations: VaultOperationCoordinator,
        audit: AuditLogger,
        readOnly: Bool = false
    ) {
        self.vaultPath = vaultPath
        self.catalog = catalog
        self.store = store
        self.mutations = mutations
        self.operations = operations
        self.audit = audit
        self.readOnly = readOnly
    }

    /// Validates, prepares, persists, commits, and audits a file creation.
    ///
    /// - Parameter request: Transport-neutral create input.
    /// - Returns: Handler-specific presentation output.
    /// - Throws: Routing, preparation, persistence, or Git errors.
    func create(_ request: CreateFileRequest) async throws -> FileOperationOutput {
        try requireMutationPermission()
        let target = try resolveWritableTarget(
            path: request.path,
            format: request.format
        )
        try FileMutationResourcePreflight.validate(request)
        let binding = try catalog.createBinding(for: request.format, in: target.area)
        let store = self.store
        let mutations = self.mutations
        let fingerprint = try MutationRequestFingerprint.make(
            operation: .create,
            request: request
        )
        let plan = VaultMutationPlan(
            kind: .create,
            target: target,
            handler: binding.id,
            mutationID: request.mutationID
        )
        return try await operations.withWrite(target: target) {
            try await mutations.executeIdempotent(
                plan: plan,
                fingerprint: fingerprint,
                prepare: {
                    try await store.requireAbsent(target)
                    let prepared = try await binding.execute(request, target)
                    try SensitiveContentPolicy.validate(
                        prepared.data,
                        format: target.format,
                        path: target.relativePath
                    )
                    // Preparation may invoke native media work. Repeat the
                    // absence check before the executor records durable intent.
                    try await store.requireAbsent(target)
                    let revision = FileSnapshot(
                        data: prepared.data,
                        modifiedDate: nil
                    ).revision
                    let output = prepared.output.withMetadata(FileOperationMetadata(
                        path: target.relativePath,
                        area: target.area,
                        revision: revision,
                        mutationID: request.mutationID,
                        replayed: false
                    ))
                    return PreparedVaultMutation(
                        requiresCommit: true,
                        perform: {
                            _ = try await store.create(
                                target: target,
                                data: prepared.data
                            )
                            return output
                        }
                    )
                }
            )
        }
    }

    /// Validates a target, routes its format-specific read, and audits access.
    ///
    /// - Parameter request: Transport-neutral read input.
    /// - Returns: Ordered text or image content blocks.
    /// - Throws: Routing, path-validation, or format-specific read errors.
    func read(_ request: ReadFileRequest) async throws -> FileOperationOutput {
        let target = try ReadableFileTarget.resolve(
            path: request.path,
            format: request.format,
            vaultPath: vaultPath
        )
        let binding = try catalog.readBinding(for: request.format, in: target.area)
        let output: FileOperationOutput
        if target.area == .notes {
            let store = self.store
            output = try await operations.withRead(target: target) {
                // The lease keeps every cooperating MCP writer off this path
                // while both the displayed content and its revision are read.
                // The confirmation also detects ordinary external edits, while
                // an uncoordinated ABA change remains outside this protocol.
                let snapshot = try await store.snapshot(target)
                let resolved = try await binding.execute(request, target)
                let confirmed = try await store.snapshot(target)
                guard confirmed.revision == snapshot.revision else {
                    throw FileRoutingError.changedDuringRead(target.relativePath)
                }
                return resolved.withMetadata(FileOperationMetadata(
                    path: target.relativePath,
                    area: target.area,
                    revision: snapshot.revision,
                    mutationID: nil,
                    replayed: false
                ))
            }
        } else {
            // References are structurally immutable through this service and
            // deliberately remain unconstrained concurrent reads.
            output = try await binding.execute(request, target).withMetadata(
                FileOperationMetadata(
                    path: target.relativePath,
                    area: target.area,
                    revision: nil,
                    mutationID: nil,
                    replayed: false
                )
            )
        }
        await audit.log(
            operation: .read,
            area: target.area,
            path: target.relativePath,
            details: binding.id.rawValue
        )
        return output
    }

    /// Prepares and atomically replaces a file when its snapshot is still current.
    ///
    /// No-op replacements are audited without creating an empty Git commit.
    ///
    /// - Parameter request: Transport-neutral update input.
    /// - Returns: Handler-specific presentation output.
    /// - Throws: Routing, stale-snapshot, persistence, or Git errors.
    func update(_ request: UpdateFileRequest) async throws -> FileOperationOutput {
        try requireMutationPermission()
        let target = try resolveWritableTarget(
            path: request.path,
            format: request.format
        )
        try FileMutationResourcePreflight.validate(request)
        let binding = try catalog.updateBinding(for: request.format, in: target.area)
        let store = self.store
        let mutations = self.mutations
        let fingerprint = try MutationRequestFingerprint.make(
            operation: .update,
            request: request
        )
        let plan = VaultMutationPlan(
            kind: .update,
            target: target,
            handler: binding.id,
            mutationID: request.mutationID
        )
        return try await operations.withWrite(target: target) {
            try await mutations.executeIdempotent(
                plan: plan,
                fingerprint: fingerprint,
                prepare: {
                    let snapshot = try await store.snapshot(target.readable)
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
                    let baseOutput = noChanges
                        ? FileOperationOutput.text("No changes: \(target.relativePath)")
                        : prepared.output
                    let output = baseOutput.withMetadata(FileOperationMetadata(
                        path: target.relativePath,
                        area: target.area,
                        revision: revision,
                        mutationID: request.mutationID,
                        replayed: false
                    ))
                    return PreparedVaultMutation(
                        requiresCommit: !noChanges,
                        perform: {
                            guard !noChanges else { return output }
                            do {
                                _ = try await store.replace(
                                    target: target,
                                    data: prepared.data,
                                    expectedRevision: request.expectedRevision
                                )
                            } catch VaultCRUDStore.StoreError.changedSinceRead {
                                throw FileRoutingError.revisionConflict(
                                    target.relativePath
                                )
                            }
                            return output
                        }
                    )
                }
            )
        }
    }

    /// Moves a writable file to `.trash/`, commits, and audits the deletion.
    ///
    /// - Parameter request: Transport-neutral delete input.
    /// - Returns: Text identifying the recoverable trash destination.
    /// - Throws: Routing, persistence, or Git errors.
    func delete(_ request: DeleteFileRequest) async throws -> FileOperationOutput {
        try requireMutationPermission()
        let target = try resolveWritableTarget(
            path: request.path,
            format: request.format
        )
        let binding = try catalog.deleteBinding(for: request.format, in: target.area)
        let store = self.store
        let mutations = self.mutations
        let fingerprint = try MutationRequestFingerprint.make(
            operation: .delete,
            request: request
        )
        let plan = VaultMutationPlan(
            kind: .delete,
            target: target,
            handler: binding.id,
            mutationID: request.mutationID
        )
        return try await operations.withWrite(target: target) {
            try await mutations.executeIdempotent(
                plan: plan,
                fingerprint: fingerprint,
                prepare: {
                    let snapshot = try await store.snapshot(target.readable)
                    guard snapshot.revision == request.expectedRevision else {
                        throw FileRoutingError.revisionConflict(target.relativePath)
                    }
                    try await binding.execute(request, target)
                    return PreparedVaultMutation(
                        requiresCommit: true,
                        performWithRecoveryEvidence: {
                            let deletion: (
                                trashPath: String,
                                deletedRevision: FileRevision
                            )
                            do {
                                deletion = try await store.softDelete(
                                    target: target,
                                    expectedRevision: request.expectedRevision
                                )
                            } catch VaultCRUDStore.StoreError.changedSinceRead {
                                throw FileRoutingError.revisionConflict(
                                    target.relativePath
                                )
                            }
                            let output = FileOperationOutput.text(
                                "Deleted \(target.relativePath) → \(deletion.trashPath)"
                            ).withMetadata(FileOperationMetadata(
                                path: target.relativePath,
                                area: target.area,
                                revision: nil,
                                mutationID: request.mutationID,
                                replayed: false
                            ))
                            return PersistedVaultMutation(
                                output: output,
                                recoveryEvidence: .softDeleted(
                                    path: deletion.trashPath,
                                    revision: deletion.deletedRevision
                                )
                            )
                        }
                    )
                }
            )
        }
    }

    private func resolveWritableTarget(
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
