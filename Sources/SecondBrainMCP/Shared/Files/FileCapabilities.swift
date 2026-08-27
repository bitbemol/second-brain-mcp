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

/// Public request and response ceilings for criteria-free vault browsing.
enum FileListingRequestLimits {
    /// Default entries returned in one response.
    static let defaultResults = 100
    /// Largest caller-selected response page.
    static let maximumResults = 500
    /// Maximum UTF-8 bytes accepted for an area-relative directory.
    static let maximumDirectoryBytes = 1_024
    /// Maximum UTF-8 bytes accepted for an opaque continuation.
    static let maximumCursorBytes = 4_096
    /// Hard ceiling on filesystem entries examined by one request.
    static let maximumScannedEntries = 100_000
}

/// Transport-neutral input for deterministic criteria-free file browsing.
struct ListFilesRequest: Sendable {
    /// Structural vault area to browse.
    let area: VaultArea
    /// Optional path relative to the selected area root.
    let directory: String?
    /// Whether descendants below the selected directory are included.
    let recursive: Bool
    /// Optional concrete-format filter; empty means every readable format in the area.
    let formats: [FileFormat]
    /// Maximum entries returned in this page.
    let limit: Int
    /// Opaque continuation from an identical preceding request.
    let cursor: String?

    init(
        area: VaultArea,
        directory: String? = nil,
        recursive: Bool = true,
        formats: [FileFormat] = [],
        limit: Int = FileListingRequestLimits.defaultResults,
        cursor: String? = nil
    ) {
        self.area = area
        self.directory = directory
        self.recursive = recursive
        self.formats = formats
        self.limit = limit
        self.cursor = cursor
    }
}

/// Lightweight descriptor-backed facts for one listed file.
struct ListedFile: Equatable, Sendable {
    let path: String
    let format: FileFormat
    let byteCount: Int
    let modifiedAt: String?
}

/// One bounded deterministic page of files.
struct ListFilesResult: Equatable, Sendable {
    let files: [ListedFile]
    let nextCursor: String?
}

/// Validation failures for a list-files request or continuation.
enum FileListingError: Error, CustomStringConvertible, Sendable {
    case invalidRequest(String)
    case invalidCursor
    case staleCursor
    case scanLimitExceeded

    var description: String {
        switch self {
        case .invalidRequest(let message):
            "Invalid list options: \(message)"
        case .invalidCursor:
            "Invalid list cursor"
        case .staleCursor:
            "List cursor is stale because the matching vault files changed; restart without cursor"
        case .scanLimitExceeded:
            "List request examined more than \(FileListingRequestLimits.maximumScannedEntries) entries; narrow directory or format filters"
        }
    }
}

/// Read-only service boundary for bounded criteria-free vault browsing.
protocol FileListingService: Sendable {
    func list(_ request: ListFilesRequest) async throws -> ListFilesResult
}
