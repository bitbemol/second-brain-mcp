/// Immutable, transport-neutral projection of effective file support.
///
/// The manifest contains only concrete formats, CRUD operations, and allowed
/// vault areas. Backend handler identities and executable closures never cross
/// this boundary.
struct FileCapabilities: Equatable, Sendable {
    /// Effective capabilities for one concrete file format.
    struct Format: Equatable, Sendable {
        /// Concrete on-disk format exposed to clients.
        let format: FileFormat
        /// Allowed vault areas keyed by supported CRUD operation.
        let operations: [FileCRUDOperation: Set<VaultArea>]
    }

    /// Registered formats sorted by their stable raw values.
    let formats: [Format]

    /// Creates a deterministic manifest from projected format capabilities.
    ///
    /// - Parameter formats: Effective operation and area support per format.
    init(formats: [Format]) {
        self.formats = formats.sorted { $0.format.rawValue < $1.format.rawValue }
    }

    /// Lists formats supporting one operation, optionally in a specific area.
    ///
    /// - Parameters:
    ///   - operation: CRUD operation required by the caller.
    ///   - area: Optional structural-area filter.
    /// - Returns: Matching concrete formats in stable order.
    func supportedFormats(
        for operation: FileCRUDOperation,
        in area: VaultArea? = nil
    ) -> [FileFormat] {
        formats.compactMap { capability in
            guard let areas = capability.operations[operation] else { return nil }
            if let area, !areas.contains(area) { return nil }
            return areas.isEmpty ? nil : capability.format
        }
    }
}
