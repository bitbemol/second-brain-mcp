import MCP

enum SearchToolResultMapper {
    static func success(_ response: VaultSearchResponse) throws -> CallTool.Result {
        try StructuredToolResultEncoder.success(
            response, maximumEncodedBytes: SearchRequestLimits.maximumStructuredResultBytes
        )
    }

    static func failure(_ message: String) -> CallTool.Result {
        ToolErrorResponse.failure(message)
    }
}
