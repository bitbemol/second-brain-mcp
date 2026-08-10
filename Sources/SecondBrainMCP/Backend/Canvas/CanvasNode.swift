/// Decoded JSON Canvas node used for structural validation.
struct CanvasNode: Decodable {
    /// Stable node identifier used by canvas edges.
    let id: String

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case x
        case y
        case width
        case height
        case color
        case text
        case file
        case subpath
        case url
        case label
        case background
        case backgroundStyle
    }

    /// Decodes required geometry and the fields belonging to the declared node kind.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)

        // Geometry is required for every node. Double accepts both integer and
        // floating-point JSON numbers without retaining unused layout values.
        _ = try container.decode(Double.self, forKey: .x)
        _ = try container.decode(Double.self, forKey: .y)
        _ = try container.decode(Double.self, forKey: .width)
        _ = try container.decode(Double.self, forKey: .height)

        if let color = try container.decodeIfPresent(String.self, forKey: .color) {
            try CanvasFieldValidator.validateColor(
                color,
                container: container,
                key: .color
            )
        }

        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            _ = try container.decode(String.self, forKey: .text)
        case "file":
            _ = try container.decode(String.self, forKey: .file)
            try CanvasFieldValidator.validateSubpath(
                try container.decodeIfPresent(String.self, forKey: .subpath),
                container: container,
                key: .subpath
            )
        case "link":
            _ = try container.decode(String.self, forKey: .url)
        case "group":
            _ = try container.decodeIfPresent(String.self, forKey: .label)
            _ = try container.decodeIfPresent(String.self, forKey: .background)
            try CanvasFieldValidator.validateBackgroundStyle(
                try container.decodeIfPresent(String.self, forKey: .backgroundStyle),
                container: container,
                key: .backgroundStyle
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown node type '\(type)'"
            )
        }
    }
}
