/// Format-specific coordinates for a structured search hit.
struct VaultSearchLocation: Codable, Equatable, Sendable {
    /// Stable JSON Canvas node identifier.
    let nodeID: String
    /// JSON Canvas node kind such as `text` or `group`.
    let nodeType: String
    /// Concrete node field whose value was searched.
    let field: String
}
