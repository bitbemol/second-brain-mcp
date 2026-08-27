/// Stable wire names accepted by `query_links`.
enum LinkQueryToolArgument: String, CaseIterable, Sendable {
    case direction
    case target
    case fromPath = "from_path"
    case groupBy = "group_by"
    case sourcePath = "source_path"
    case limit
    case cursor
}
