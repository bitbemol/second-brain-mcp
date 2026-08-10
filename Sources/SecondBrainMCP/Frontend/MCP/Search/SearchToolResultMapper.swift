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
                return .object(item)
            }),
        ]
        if let cursor = response.nextCursor {
            values["next_cursor"] = .string(cursor)
        }
        return .object(values)
    }
}
