/// Reusable binding assembly for text formats backed by generic vault snapshots.
///
/// The family centralizes stored-text ingress, the shared notes policy, snapshot
/// loading, and soft deletion. Concrete resolvers retain only format semantics.
struct StoredTextFileOperationFamily: Sendable {
    private let store: VaultCRUDStore
    private let delete: DeleteOperationBinding
    private let ingress = TextFileIngress()

    /// Creates the reusable stored-text binding family.
    ///
    /// - Parameters:
    ///   - store: Generic persistence actor used to load consistent snapshots.
    ///   - delete: Shared recoverable-delete behavior.
    init(store: VaultCRUDStore, delete: DeleteOperationBinding) {
        self.store = store
        self.delete = delete
    }

    /// Registers one concrete text format using generic persistence mechanics.
    ///
    /// - Parameters:
    ///   - format: Concrete on-disk text format.
    ///   - create: Persistence-free resolver for validated inline bytes.
    ///   - read: Snapshot interpreter.
    ///   - update: Optional persistence-free update preparation.
    /// - Returns: A complete notes-area routing definition.
    func definition(
        format: FileFormat,
        create: @escaping StoredTextCreateResolver,
        read: @escaping StoredReadResolver,
        update: UpdateFileFunction? = nil
    ) -> FileFormatDefinition {
        FileFormatDefinition(
            format: format,
            operations: FormatOperations(
                create: storedCreate(resolve: create),
                read: storedRead(resolve: read),
                update: update.map {
                    UpdateOperationBinding(
                        allowedAreas: [.notes],
                        execute: $0
                    )
                },
                delete: delete
            )
        )
    }

    private func storedCreate(
        resolve: @escaping StoredTextCreateResolver
    ) -> CreateOperationBinding {
        CreateOperationBinding(allowedAreas: [.notes]) { request, target in
            let input = try ingress.prepare(request, for: target)
            return try resolve(input, target)
        }
    }

    private func storedRead(
        resolve: @escaping StoredReadResolver
    ) -> ReadOperationBinding {
        ReadOperationBinding(allowedAreas: [.notes]) { request, target in
            let snapshot = try await store.snapshot(target)
            return try resolve(request, target, snapshot)
        }
    }
}
