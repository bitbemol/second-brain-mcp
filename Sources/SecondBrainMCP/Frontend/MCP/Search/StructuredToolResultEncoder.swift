import Foundation
import MCP

/// Produces one JSON representation shared by text fallback and structured output.
enum StructuredToolResultEncoder {
    private struct OutputLimitExceeded: Error {}

    static func success<Response: Encodable>(
        _ response: Response, maximumEncodedBytes: Int? = nil
    ) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(response)
        if let maximumEncodedBytes, data.count > maximumEncodedBytes {
            throw OutputLimitExceeded()
        }
        return try CallTool.Result(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            structuredContent: try JSONDecoder().decode(Value.self, from: data)
        )
    }
}
