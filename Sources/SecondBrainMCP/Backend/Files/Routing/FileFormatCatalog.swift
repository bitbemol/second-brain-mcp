/// Immutable backend lookup table for concrete format routing.
///
/// The catalog is the single authority for resolving a declared format into an
/// operation binding and enforcing that binding's structural-area policy.
struct FileFormatCatalog: Sendable {
    private let definitions: [FileFormat: FileFormatDefinition]

    /// Builds a catalog keyed by concrete format.
    ///
    /// - Parameter definitions: One unique definition per registered format.
    init(definitions: [FileFormatDefinition]) {
        self.definitions = Dictionary(
            uniqueKeysWithValues: definitions.map { ($0.format, $0) }
        )
    }

    /// Resolves authorized create behavior for a concrete format and area.
    func createBinding(
        for format: FileFormat,
        in area: VaultArea
    ) throws -> CreateOperationBinding {
        try binding(for: format, operation: .create, in: area, at: \.create)
    }

    /// Resolves authorized read behavior for a concrete format and area.
    func readBinding(
        for format: FileFormat,
        in area: VaultArea
    ) throws -> ReadOperationBinding {
        try binding(for: format, operation: .read, in: area, at: \.read)
    }

    /// Resolves authorized update behavior for a concrete format and area.
    func updateBinding(
        for format: FileFormat,
        in area: VaultArea
    ) throws -> UpdateOperationBinding {
        try binding(for: format, operation: .update, in: area, at: \.update)
    }

    /// Resolves authorized delete behavior for a concrete format and area.
    func deleteBinding(
        for format: FileFormat,
        in area: VaultArea
    ) throws -> DeleteOperationBinding {
        try binding(for: format, operation: .delete, in: area, at: \.delete)
    }

    /// Projects routing registrations into transport-neutral capability data.
    ///
    /// - Returns: An immutable manifest without handler identities or closures.
    func capabilities() -> FileCapabilities {
        FileCapabilities(formats: definitions.values.map { definition in
            return FileCapabilities.Format(
                format: definition.format,
                operations: definition.operations.allowedAreasByOperation
            )
        })
    }

    private func binding<Handler: Sendable>(
        for format: FileFormat,
        operation: FileCRUDOperation,
        in area: VaultArea,
        at keyPath: KeyPath<FormatOperations, FileOperationBinding<Handler>?>
    ) throws -> FileOperationBinding<Handler> {
        guard let definition = definitions[format] else {
            throw FileRoutingError.unknownFormat(format.rawValue)
        }
        guard let binding = definition.operations[keyPath: keyPath],
              binding.allowedAreas.contains(area) else {
            throw FileRoutingError.operationNotSupported(
                format: format,
                operation: operation,
                area: area
            )
        }
        return binding
    }
}
