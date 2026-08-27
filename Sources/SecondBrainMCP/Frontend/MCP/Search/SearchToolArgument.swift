/// Stable wire names accepted by `search_vault`.
enum SearchToolArgument: String, CaseIterable, Sendable {
    case location
    case directory
    case formats
    case query
    case tags
    case createdFrom = "created_from"
    case createdThrough = "created_through"
    case limit
    case cursor
}

extension Dictionary where Key == String {
    subscript(argument: SearchToolArgument) -> Value? {
        get { self[argument.rawValue] }
        set { self[argument.rawValue] = newValue }
    }
}
