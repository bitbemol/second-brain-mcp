/// Decoded JSON Canvas node with its summary-safe projection.
struct CanvasNode: Decodable {
    /// Stable node identifier used by canvas edges.
    let id: String
    /// Validated presentation data consumed by canvas reads.
    let inspection: CanvasInspection.Node

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
        // floating-point JSON numbers without preserving unused layout values.
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
        inspection = try Self.inspection(
            for: type,
            id: id,
            container: container
        )
    }

    /// Decodes variant-specific fields and projects them for read summaries.
    private static func inspection(
        for type: String,
        id: String,
        container: KeyedDecodingContainer<CodingKeys>
    ) throws -> CanvasInspection.Node {
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            let label = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return CanvasInspection.Node(
                id: id,
                kind: .text,
                label: label,
                searchText: text,
                filePath: nil
            )
        case "file":
            let file = try container.decode(String.self, forKey: .file)
            try CanvasFieldValidator.validateSubpath(
                try container.decodeIfPresent(String.self, forKey: .subpath),
                container: container,
                key: .subpath
            )
            return CanvasInspection.Node(
                id: id,
                kind: .file,
                label: file,
                searchText: file,
                filePath: file
            )
        case "link":
            let url = try container.decode(String.self, forKey: .url)
            return CanvasInspection.Node(
                id: id,
                kind: .link,
                label: url,
                searchText: url,
                filePath: nil
            )
        case "group":
            let label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
            _ = try container.decodeIfPresent(String.self, forKey: .background)
            try CanvasFieldValidator.validateBackgroundStyle(
                try container.decodeIfPresent(String.self, forKey: .backgroundStyle),
                container: container,
                key: .backgroundStyle
            )
            return CanvasInspection.Node(
                id: id,
                kind: .group,
                label: label,
                searchText: label,
                filePath: nil
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
