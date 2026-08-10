/// Reusable binding assembly for concrete image formats.
///
/// Every registered image shares content-aware reading in notes and references,
/// has no update behavior, and uses the common recoverable-delete binding. A
/// concrete format may additionally provide its own create resolver.
struct ImageFileOperationFamily: Sendable {
    private let read: ReadOperationBinding
    private let delete: DeleteOperationBinding

    /// Creates the shared image binding family.
    ///
    /// - Parameters:
    ///   - read: Content-aware image resolver shared by every concrete format.
    ///   - delete: Shared recoverable-delete behavior.
    init(
        read: @escaping ReadFileFunction,
        delete: DeleteOperationBinding
    ) {
        self.read = ReadOperationBinding(
            allowedAreas: [.notes, .references],
            execute: read
        )
        self.delete = delete
    }

    /// Registers an image format that supports reading and deletion only.
    ///
    /// - Parameter format: Concrete on-disk image format.
    /// - Returns: An immutable routing definition using the shared resolvers.
    func definition(_ format: FileFormat) -> FileFormatDefinition {
        definition(format, create: nil)
    }

    /// Registers an image format with custom creation behavior.
    ///
    /// - Parameters:
    ///   - format: Concrete on-disk image format.
    ///   - create: Persistence-free image or video preparation.
    /// - Returns: An immutable routing definition using the custom create and
    ///   shared read/delete resolvers.
    func definition(
        _ format: FileFormat,
        create: @escaping CreateFileFunction
    ) -> FileFormatDefinition {
        definition(
            format,
            create: CreateOperationBinding(
                allowedAreas: [.notes],
                execute: create
            )
        )
    }

    private func definition(
        _ format: FileFormat,
        create: CreateOperationBinding?
    ) -> FileFormatDefinition {
        FileFormatDefinition(
            format: format,
            operations: FormatOperations(
                create: create,
                read: read,
                update: nil,
                delete: delete
            )
        )
    }
}
