import Foundation

/// JSON Canvas 1.0 validation. See https://jsoncanvas.org/spec/1.0/
///
/// This decodes canvas content **only to prove it is well-formed** — it is never
/// re-serialized. `CanvasManager` writes the caller's original bytes, so extra
/// keys that Obsidian or its plugins add (outside the 1.0 spec) survive intact.
/// "Reject, don't sanitize": invalid content is thrown, never patched.
enum CanvasModel {

    enum CanvasError: Error, CustomStringConvertible {
        case malformed(String)
        case duplicateNodeID(String)
        case danglingEdge(edge: String, missingNode: String)

        var description: String {
            switch self {
            case .malformed(let reason): return "Invalid canvas JSON: \(reason)"
            case .duplicateNodeID(let id): return "Duplicate node id: \(id)"
            case .danglingEdge(let edge, let node): return "Edge '\(edge)' references missing node: '\(node)'"
            }
        }
    }

    /// Validate canvas JSON: structural decode + unique node ids + edges that
    /// reference existing nodes. Throws `CanvasError` on any violation.
    static func validate(jsonData: Data) throws {
        let canvas: Canvas
        do {
            canvas = try JSONDecoder().decode(Canvas.self, from: jsonData)
        } catch let error as DecodingError {
            throw CanvasError.malformed(describe(error))
        } catch {
            throw CanvasError.malformed(error.localizedDescription)
        }

        var ids = Set<String>()
        for node in canvas.nodes ?? [] {
            guard ids.insert(node.id).inserted else {
                throw CanvasError.duplicateNodeID(node.id)
            }
        }
        for edge in canvas.edges ?? [] {
            if !ids.contains(edge.fromNode) {
                throw CanvasError.danglingEdge(edge: edge.id, missingNode: edge.fromNode)
            }
            if !ids.contains(edge.toNode) {
                throw CanvasError.danglingEdge(edge: edge.id, missingNode: edge.toNode)
            }
        }
    }

    // MARK: - Decodable shapes (validation only)

    private struct Canvas: Decodable {
        let nodes: [Node]?
        let edges: [Edge]?
    }

    private struct Node: Decodable {
        let id: String

        enum CodingKeys: String, CodingKey {
            case id, type, x, y, width, height, color
            case text, file, subpath, url, label, background, backgroundStyle
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)

            // Geometry is required for every node. Decode as Double so integer or
            // float JSON numbers both pass (geometry isn't security-sensitive).
            _ = try c.decode(Double.self, forKey: .x)
            _ = try c.decode(Double.self, forKey: .y)
            _ = try c.decode(Double.self, forKey: .width)
            _ = try c.decode(Double.self, forKey: .height)

            if let color = try c.decodeIfPresent(String.self, forKey: .color) {
                try validateColor(color, container: c, key: .color)
            }

            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "text":
                _ = try c.decode(String.self, forKey: .text)
            case "file":
                _ = try c.decode(String.self, forKey: .file)
                if let subpath = try c.decodeIfPresent(String.self, forKey: .subpath), !subpath.hasPrefix("#") {
                    throw DecodingError.dataCorruptedError(forKey: .subpath, in: c, debugDescription: "subpath must start with '#'")
                }
            case "link":
                _ = try c.decode(String.self, forKey: .url)
            case "group":
                _ = try c.decodeIfPresent(String.self, forKey: .label)
                _ = try c.decodeIfPresent(String.self, forKey: .background)
                if let style = try c.decodeIfPresent(String.self, forKey: .backgroundStyle),
                   !["cover", "ratio", "repeat"].contains(style) {
                    throw DecodingError.dataCorruptedError(forKey: .backgroundStyle, in: c, debugDescription: "backgroundStyle must be cover, ratio, or repeat")
                }
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown node type '\(type)'")
            }
        }
    }

    private struct Edge: Decodable {
        let id: String
        let fromNode: String
        let toNode: String

        enum CodingKeys: String, CodingKey {
            case id, fromNode, toNode, fromSide, toSide, fromEnd, toEnd, color, label
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            fromNode = try c.decode(String.self, forKey: .fromNode)
            toNode = try c.decode(String.self, forKey: .toNode)

            try validateSide(try c.decodeIfPresent(String.self, forKey: .fromSide), container: c, key: .fromSide)
            try validateSide(try c.decodeIfPresent(String.self, forKey: .toSide), container: c, key: .toSide)
            try validateEnd(try c.decodeIfPresent(String.self, forKey: .fromEnd), container: c, key: .fromEnd)
            try validateEnd(try c.decodeIfPresent(String.self, forKey: .toEnd), container: c, key: .toEnd)
            _ = try c.decodeIfPresent(String.self, forKey: .label)
            if let color = try c.decodeIfPresent(String.self, forKey: .color) {
                try validateColor(color, container: c, key: .color)
            }
        }
    }

    // MARK: - Field validators

    private static func validateSide<K: CodingKey>(_ value: String?, container: KeyedDecodingContainer<K>, key: K) throws {
        guard let value else { return }
        guard ["top", "right", "bottom", "left"].contains(value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "side must be top, right, bottom, or left")
        }
    }

    private static func validateEnd<K: CodingKey>(_ value: String?, container: KeyedDecodingContainer<K>, key: K) throws {
        guard let value else { return }
        guard ["none", "arrow"].contains(value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "end must be none or arrow")
        }
    }

    /// canvasColor is a hex string ("#RGB"/"#RRGGBB") or a preset "1"–"6".
    private static func validateColor<K: CodingKey>(_ value: String, container: KeyedDecodingContainer<K>, key: K) throws {
        if ["1", "2", "3", "4", "5", "6"].contains(value) { return }
        if value.hasPrefix("#") {
            let hex = value.dropFirst()
            if (hex.count == 3 || hex.count == 6), hex.allSatisfy(\.isHexDigit) { return }
        }
        throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "color must be a hex value (e.g. #FF0000) or a preset 1–6")
    }

    // MARK: - Error formatting

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx):
            return "missing field '\(key.stringValue)'\(location(ctx))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            return "\(ctx.debugDescription)\(location(ctx))"
        case .dataCorrupted(let ctx):
            return ctx.debugDescription.isEmpty ? "malformed JSON" : "\(ctx.debugDescription)\(location(ctx))"
        @unknown default:
            return "invalid structure"
        }
    }

    private static func location(_ ctx: DecodingError.Context) -> String {
        let path = ctx.codingPath.map(\.stringValue).filter { !$0.isEmpty }
        return path.isEmpty ? "" : " (at \(path.joined(separator: " → ")))"
    }
}
