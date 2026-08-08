/// Stable wire names accepted by `search_vault`.
enum SearchToolArgument: String, CaseIterable, Sendable {
    case query
    case strategy
    case fields
    case formats
    case areas
    case pathPrefix = "path_prefix"
    case limit
    case minimumRelevance = "minimum_relevance"
    case maxHitsPerFile = "max_hits_per_file"
    case cursor
}

extension Dictionary where Key == String {
    subscript(argument: SearchToolArgument) -> Value? {
        get { self[argument.rawValue] }
        set { self[argument.rawValue] = newValue }
    }
}
