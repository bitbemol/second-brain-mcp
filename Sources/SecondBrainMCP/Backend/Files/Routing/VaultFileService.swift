import Foundation

/// Single backend interface for generic file CRUD. It validates declared format,
/// vault area, extension, and operation policy; delegates format semantics to the
/// selected binding; then delegates prepared mutations to the transaction boundary.
actor VaultFileService: FileCRUDService {
    private let catalog: FileFormatCatalog
    private let vaultPath: String
    private let store: VaultCRUDStore
    private let mutations: VaultMutationExecutor
    private let audit: AuditLogger
    private let readOnly: Bool

    /// Creates the single routed CRUD service.
    ///
    /// - Parameters:
    ///   - vaultPath: Canonical vault root.
    ///   - catalog: Immutable format-operation registrations.
    ///   - store: Sole generic persistence actor.
    ///   - mutations: Serialized persistence, Git, and audit transaction boundary.
    ///   - audit: Append-only operation log.
    ///   - readOnly: Whether mutation methods must fail before resolving or writing.
    init(
        vaultPath: String,
        catalog: FileFormatCatalog,
        store: VaultCRUDStore,
        mutations: VaultMutationExecutor,
        audit: AuditLogger,
        readOnly: Bool = false
    ) {
        self.vaultPath = vaultPath
        self.catalog = catalog
        self.store = store
        self.mutations = mutations
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
        let binding = try catalog.createBinding(for: request.format, in: target.area)
        let prepared = try await binding.execute(request, target)

        let store = self.store
        _ = try await mutations.execute(
            VaultMutationPlan(
                kind: .create,
                target: target,
                handler: binding.id
            ),
            apply: {
                try await store.create(target: target, data: prepared.data)
            }
        )
        return prepared.output
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
        let output = try await binding.execute(request, target)
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
        let binding = try catalog.updateBinding(for: request.format, in: target.area)
        let snapshot = try await store.snapshot(target.readable)
        let prepared = try await binding.execute(request, target, snapshot)
        if prepared.data == snapshot.data {
            await audit.log(
                operation: .update,
                path: target.relativePath,
                details: "\(binding.id.rawValue); no changes"
            )
            return .text("No changes: \(target.relativePath)")
        }

        let store = self.store
        _ = try await mutations.execute(
            VaultMutationPlan(
                kind: .update,
                target: target,
                handler: binding.id
            ),
            apply: {
                try await store.replace(target: target, data: prepared.data, expected: snapshot)
            }
        )
        return prepared.output
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
        try await binding.execute(request, target)

        let store = self.store
        let trashPath = try await mutations.execute(
            VaultMutationPlan(
                kind: .delete,
                target: target,
                handler: binding.id
            ),
            apply: {
                try await store.softDelete(target: target)
            }
        )
        return .text("Deleted \(target.relativePath) → \(trashPath)")
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
