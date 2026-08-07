import Foundation
import MCP

/// Maps transport-neutral search results into escaped MCP values.
enum SearchToolResultMapper {
    static func success(_ response: VaultSearchResponse) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try String(decoding: encoder.encode(response), as: UTF8.self)
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
        .object([
            "strategy": .string(response.strategy.rawValue),
            "results": .array(response.results.map(resultValue)),
            "searched_file_count": .int(response.searchedFileCount),
            "skipped_file_count": .int(response.skippedFileCount),
            "skipped_sensitive_file_count": .int(response.skippedSensitiveFileCount),
            "truncated": .bool(response.truncated),
        ])
    }

    private static func resultValue(_ result: VaultSearchResult) -> Value {
        var values: [String: Value] = [
            "path": .string(result.path),
            "format": .string(result.format.rawValue),
            "title": .string(result.title),
            "snippet": .string(result.snippet),
            "line_start": .int(result.lineStart),
            "line_end": .int(result.lineEnd),
            "matched_fields": .array(result.matchedFields.map { .string($0.rawValue) }),
        ]
        if let heading = result.heading { values["heading"] = .string(heading) }
        if let location = result.location {
            values["location"] = .object([
                "node_id": .string(location.nodeID),
                "node_type": .string(location.nodeType),
                "field": .string(location.field),
            ])
        }
        return .object(values)
    }
}
