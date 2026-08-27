/// Stable public ceilings for the small search contract.
enum SearchRequestLimits {
    static let maximumQueryBytes = 1_024
    static let maximumTags = 32
    static let maximumTagBytes = 128
    static let maximumDateBytes = 10
    static let defaultResults = 20
    static let maximumResults = 50
    static let maximumCursorBytes = 1_024
    /// Exact standalone locator JSON; whole identifiers are never shortened.
    static let maximumLocatorBytes = 4 * 1_024
    static let maximumStructuredResultBytes = 256 * 1_024
    /// Mirrored CallTool.Result, excluding the caller-controlled JSON-RPC envelope.
    static let maximumCallToolResultBytes = 768 * 1_024
    static let maximumIndexedFiles = 10_000
    static let maximumScannedEntries = 100_000
    static let maximumCorpusBytes = 256 * 1_024 * 1_024
    static let maximumAtoms = 100_000
}

/// Safe request-validation failures that may cross the backend/frontend boundary.
enum VaultSearchRequestError: Error, CustomStringConvertible, Sendable {
    case invalidScope
    case directoryNotFound
    case unsupportedFormats([FileFormat], location: VaultArea)
    case busy
    case workBudgetExceeded
    case missingCriteria
    case queryTooLarge(limit: Int)
    case invalidTags
    case invalidDate(String)
    case invalidDateRange
    case metadataFiltersRequireNotes
    case invalidLimit(maximum: Int)
    case invalidCursor
    case staleCursor
    case corpusTooLarge(files: Int, bytes: Int, atoms: Int)

    var description: String {
        switch self {
        case .busy:
            "Search is busy; retry after current work finishes"
        case .directoryNotFound:
            "Search directory not found; choose an existing area-relative directory or omit directory to search the area."
        case .invalidScope:
            "Search scope must select an existing visible area-relative directory and compatible filters"
        case .unsupportedFormats(let formats, let location):
            "Search is not supported for \(Set(formats).map(\.rawValue).sorted().joined(separator: ", ")) in \(location.rawValue). "
                + "Use list_files to locate those files and read_file to inspect them, or select advertised searchable formats. No files were searched."
        case .workBudgetExceeded:
            "Search work budget exceeded; narrow directory or formats. Lowering limit does not reduce scan work."
        case .missingCriteria:
            "Provide a non-empty query, at least one tag, or a created-date bound"
        case .queryTooLarge(let limit):
            "Search query exceeds the \(limit)-byte limit"
        case .invalidTags:
            "Search tags must be unique non-empty values within the advertised limits"
        case .invalidDate(let name):
            "\(name) must be a real date formatted as YYYY-MM-DD"
        case .invalidDateRange:
            "created_from must be earlier than or equal to created_through"
        case .metadataFiltersRequireNotes:
            "Tag and created-date filters are available only for notes"
        case .invalidLimit(let maximum):
            "Search limit must be between 1 and \(maximum)"
        case .invalidCursor:
            "Search cursor is invalid or belongs to a different request"
        case .staleCursor:
            "Search cursor is stale because the vault changed; restart the search"
        case .corpusTooLarge(let files, let bytes, let atoms):
            "Search corpus exceeds its safe ceiling (files: \(files), bytes: \(bytes), atoms: \(atoms))"
        }
    }
}
