/// Decoded JSON Canvas 1.0 document used during validation.
///
/// Missing or `null` node and edge collections are treated as empty, matching
/// the format's empty-document representation. Unknown keys remain accepted so
/// Obsidian and plugin extensions can coexist with the standard fields.
struct CanvasDocument: Decodable {
    /// Nodes in source order.
    let nodes: [CanvasNode]
    /// Edges in source order.
    let edges: [CanvasEdge]

    private enum CodingKeys: String, CodingKey {
        case nodes
        case edges
    }

    /// Decodes the standard top-level collections without rejecting extra keys.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decodeIfPresent([CanvasNode].self, forKey: .nodes) ?? []
        edges = try container.decodeIfPresent([CanvasEdge].self, forKey: .edges) ?? []
    }
}
