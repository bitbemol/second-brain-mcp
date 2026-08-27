import MCP

/// Maps locator-only graph output without duplicating its Codable representation.
enum LinkQueryToolResultMapper {
    static func success(_ response: LinkQueryResponse) throws -> CallTool.Result {
        try StructuredToolResultEncoder.success(response)
    }
}
