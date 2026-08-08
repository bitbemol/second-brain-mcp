/// Stable wire names accepted by `search_vault`.
enum SearchToolArgument: String, CaseIterable, Sendable {
    case query
    case strategy
    case fields
    case formats
    case pathPrefix = "path_prefix"
    case limit
    case minimumRelevance = "minimum_relevance"
}

extension Dictionary where Key == String {
    subscript(argument: SearchToolArgument) -> Value? {
        get { self[argument.rawValue] }
        set { self[argument.rawValue] = newValue }
    }
}
