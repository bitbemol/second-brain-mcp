/// Stable public ceilings for the small search contract.
enum SearchRequestLimits {
    static let maximumQueryBytes = 1_024
    static let maximumTags = 32
    static let maximumTagBytes = 128
    static let maximumDateBytes = 10
    static let defaultResults = 20
    static let maximumResults = 50
    static let maximumCursorBytes = 1_024
    static let maximumIndexedFiles = 10_000
    static let maximumScannedEntries = 100_000
    static let maximumCorpusBytes = 64 * 1_024 * 1_024
    static let maximumAtoms = 100_000
}

/// Stable public ceilings for bounded link queries.
enum LinkQueryLimits {
    static let maximumTargetBytes = 1_024
    static let defaultResults = 20
    static let maximumResults = 50
    static let maximumCursorBytes = 1_024
    static let maximumIndexedFiles = 10_000
    static let maximumMarkdownBytes = 64 * 1_024 * 1_024
    static let maximumMatchingResults = 100_000
}

/// Safe request-validation failures that may cross the backend/frontend boundary.
enum LinkQueryError: Error, CustomStringConvertible, Sendable {
    case emptyTarget
    case targetTooLarge(limit: Int)
    case invalidTarget
    case invalidFromPath
    case invalidLimit(maximum: Int)
    case invalidCursor
    case staleCursor
    case corpusTooLarge(files: Int, bytes: Int)
    case resultSetTooLarge(limit: Int)

    var description: String {
        switch self {
        case .emptyTarget:
            "Link target must not be empty"
        case .targetTooLarge(let limit):
            "Link target exceeds the \(limit)-byte limit"
        case .invalidTarget:
            "Link target is invalid"
        case .invalidFromPath:
            "from_path must identify an existing supported Markdown note"
        case .invalidLimit(let maximum):
            "Link-query limit must be between 1 and \(maximum)"
        case .invalidCursor:
            "Link-query cursor is invalid or belongs to a different request"
        case .staleCursor:
            "Link-query cursor is stale because the vault changed; restart the query"
        case .corpusTooLarge(let files, let bytes):
            "Link-query corpus exceeds its safe ceiling (files: \(files), bytes: \(bytes))"
        case .resultSetTooLarge(let limit):
            "Link query exceeds the \(limit)-result safety ceiling"
        }
    }
}

/// Safe request-validation failures that may cross the backend/frontend boundary.
enum VaultSearchRequestError: Error, CustomStringConvertible, Sendable {
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
