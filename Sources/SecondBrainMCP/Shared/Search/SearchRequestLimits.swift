/// Stable public ceilings for the small search contract.
enum SearchRequestLimits {
    static let maximumQueryBytes = 1_024
    static let maximumTags = 32
    static let maximumTagBytes = 128
    static let maximumDateBytes = 10
    static let defaultResults = 20
    static let maximumResults = 50
    static let maximumCursorBytes = 1_024
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
        }
    }
}
