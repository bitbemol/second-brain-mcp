/// Decoded JSON Canvas edge used for endpoint validation.
struct CanvasEdge: Decodable {
    /// Stable edge identifier used in validation diagnostics.
    let id: String
    /// Identifier of the source node.
    let fromNode: String
    /// Identifier of the destination node.
    let toNode: String

    private enum CodingKeys: String, CodingKey {
        case id
        case fromNode
        case toNode
        case fromSide
        case toSide
        case fromEnd
        case toEnd
        case color
        case label
    }

    /// Decodes the required endpoints and validates optional presentation fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fromNode = try container.decode(String.self, forKey: .fromNode)
        toNode = try container.decode(String.self, forKey: .toNode)

        try CanvasFieldValidator.validateSide(
            try container.decodeIfPresent(String.self, forKey: .fromSide),
            container: container,
            key: .fromSide
        )
        try CanvasFieldValidator.validateSide(
            try container.decodeIfPresent(String.self, forKey: .toSide),
            container: container,
            key: .toSide
        )
        try CanvasFieldValidator.validateEnd(
            try container.decodeIfPresent(String.self, forKey: .fromEnd),
            container: container,
            key: .fromEnd
        )
        try CanvasFieldValidator.validateEnd(
            try container.decodeIfPresent(String.self, forKey: .toEnd),
            container: container,
            key: .toEnd
        )
        _ = try container.decodeIfPresent(String.self, forKey: .label)
        if let color = try container.decodeIfPresent(String.self, forKey: .color) {
            try CanvasFieldValidator.validateColor(
                color,
                container: container,
                key: .color
            )
        }
    }
}
