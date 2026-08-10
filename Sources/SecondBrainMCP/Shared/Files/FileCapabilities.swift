/// Public, transport-neutral description of one format's creation input.
struct FileCreateContract: Equatable, Sendable {
    /// Caller payload accepted by the format's create handler.
    enum Input: String, Codable, Sendable {
        /// UTF-8 data supplied through `content`.
        case content
        /// External regular file supplied through `source`.
        case source
    }

    /// Required payload field.
    let input: Input
    /// Required transformation when the source cannot be stored directly.
    let transform: FileCreateTransform?
    /// Whether Markdown-style tags are accepted.
    let acceptsTags: Bool

    /// Standard inline-content creation contract.
    static let content = FileCreateContract(
        input: .content,
        transform: nil,
        acceptsTags: false
    )
}

/// Immutable, transport-neutral projection of effective file support.
///
/// The manifest contains only concrete formats, CRUD operations, allowed vault
/// areas, creation inputs, and update modes. Backend handler identities and
/// executable closures never cross this boundary.
struct FileCapabilities: Equatable, Sendable {
    /// Effective capabilities for one concrete file format.
    struct Format: Equatable, Sendable {
        /// Concrete on-disk format exposed to clients.
        let format: FileFormat
        /// Allowed vault areas keyed by supported CRUD operation.
        let operations: [FileCRUDOperation: Set<VaultArea>]
        /// Input accepted by create, or nil when creation is unsupported.
        let createContract: FileCreateContract?
        /// Update modes accepted by the registered update operation.
        let updateModes: Set<FileUpdateMode>

        init(
            format: FileFormat,
            operations: [FileCRUDOperation: Set<VaultArea>],
            createContract: FileCreateContract? = nil,
            updateModes: Set<FileUpdateMode> = []
        ) {
            self.format = format
            self.operations = operations
            self.createContract = createContract
            self.updateModes = updateModes
        }
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
