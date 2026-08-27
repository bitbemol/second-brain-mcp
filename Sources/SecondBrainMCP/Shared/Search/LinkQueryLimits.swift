/// Stable public ceilings for bounded link queries.
enum LinkQueryLimits {
    static let maximumTargetBytes = 1_024
    static let defaultResults = 20
    static let maximumResults = 50
    static let maximumCursorBytes = 1_024
}

/// Safe request-validation failures that may cross the backend/frontend boundary.
enum LinkQueryError: Error, CustomStringConvertible, Sendable {
    case emptyTarget
    case targetTooLarge(limit: Int)
    case invalidTarget
    case invalidFromPath
    case invalidSourcePath
    case invalidProjection
    case workBudgetExceeded
    case invalidLimit(maximum: Int)
    case invalidCursor
    case staleCursor
    case corpusTooLarge(files: Int, bytes: Int)

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
        case .invalidSourcePath:
            "source_path must identify an existing supported Markdown note"
        case .invalidProjection:
            "group_by and source_path apply only to backlinks"
        case .workBudgetExceeded:
            "Link-query work budget exceeded; restrict backlink source_path or query outgoing links. Lowering limit does not reduce scan work."
        case .invalidLimit(let maximum):
            "Link-query limit must be between 1 and \(maximum)"
        case .invalidCursor:
            "Link-query cursor is invalid or belongs to a different request"
        case .staleCursor:
            "Link-query cursor is stale because the vault changed; restart the query"
        case .corpusTooLarge(let files, let bytes):
            "Link-query corpus exceeds its safe ceiling (files: \(files), bytes: \(bytes))"
        }
    }
}
