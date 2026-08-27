import Foundation
import MCP

/// Maps locator-only search output to identical text and structured MCP values.
enum SearchToolResultMapper {
    static func success(_ response: VaultSearchResponse) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = String(decoding: try encoder.encode(response), as: UTF8.self)
        return try CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)],
            structuredContent: structuredContent(response)
        )
    }

    static func success(_ response: LinkQueryResponse) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = String(decoding: try encoder.encode(response), as: UTF8.self)
        return try CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)],
            structuredContent: structuredContent(response)
        )
    }

    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private static func structuredContent(_ response: VaultSearchResponse) -> Value {
        var values: [String: Value] = [
            "results": .array(response.results.map { result in
                var item: [String: Value] = [
                    "path": .string(result.path),
                    "format": .string(result.format.rawValue),
                ]
                if let page = result.page { item["page"] = .int(page) }
                if let nodeID = result.canvasNodeID {
                    item["canvas_node_id"] = .string(nodeID)
                }
                if let field = result.canvasField {
                    item["canvas_field"] = .string(field)
                }
                return .object(item)
            }),
        ]
        if let cursor = response.nextCursor {
            values["next_cursor"] = .string(cursor)
        }
        return .object(values)
    }

    private static func structuredContent(_ response: LinkQueryResponse) -> Value {
        let resultValues = response.results.map { result -> Value in
            var item: [String: Value] = [
                "target": .string(result.target),
                "kind": .string(result.kind.rawValue),
                "ambiguous": .bool(result.ambiguous),
            ]
            if let sourcePath = result.sourcePath {
                item["source_path"] = .string(sourcePath)
            }
            if let resolvedPath = result.resolvedPath {
                item["resolved_path"] = .string(resolvedPath)
            }
            if let alias = result.alias {
                item["alias"] = .string(alias)
            }
            if let occurrence = result.occurrence {
                item["occurrence"] = .int(occurrence)
            }
            return .object(item)
        }
        var values: [String: Value] = [
            "direction": .string(response.direction.rawValue),
            "results": .array(resultValues),
        ]
        if let cursor = response.nextCursor {
            values["next_cursor"] = .string(cursor)
        }
        return .object(values)
    }
}
