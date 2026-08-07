/// Stable public ceilings advertised and enforced for search requests.
enum SearchRequestLimits {
    /// Maximum UTF-8 bytes accepted in a query.
    static let maximumQueryBytes = 1_024
    /// Maximum UTF-8 bytes accepted in a vault-relative search prefix.
    static let maximumPathPrefixBytes = 4_096
    /// Default number of different files returned.
    static let defaultResults = 20
    /// Maximum number of different files returned.
    static let maximumResults = 50
    /// Maximum encoded MCP tool-result bytes returned by one search call.
    static let maximumWireResponseBytes = 64 * 1_024
}

/// Safe request-validation failures that may cross the backend/frontend boundary.
enum VaultSearchRequestError: Error, CustomStringConvertible, Sendable {
    case emptyQuery
    case queryTooLarge(limit: Int)
    case tooManyQueryTokens(limit: Int)
    case tokenTooLarge(limit: Int)
    case invalidLimit(maximum: Int)
    case unsupportedFormat(FileFormat)
    case emptySelection(String)
    case invalidSelection(String)
    case invalidPathPrefix
    case searchBusy

    var description: String {
        switch self {
        case .emptyQuery:
            "Search query must contain non-whitespace text"
        case .queryTooLarge(let limit):
            "Search query exceeds the \(limit)-byte limit"
        case .tooManyQueryTokens(let limit):
            "Search query exceeds the \(limit)-token limit"
        case .tokenTooLarge(let limit):
            "Search query contains a token longer than \(limit) Unicode scalars"
        case .invalidLimit(let maximum):
            "Search limit must be between 1 and \(maximum)"
        case .unsupportedFormat(let format):
            "Format is not searchable: \(format.rawValue)"
        case .emptySelection(let name):
            "Search \(name) must not be an empty array; omit it to search all"
        case .invalidSelection(let name):
            "Search \(name) contains duplicates or too many values"
        case .invalidPathPrefix:
            "path_prefix must be a safe directory under notes/"
        case .searchBusy:
            "Search is at capacity; retry after an active search finishes"
        }
    }
}
