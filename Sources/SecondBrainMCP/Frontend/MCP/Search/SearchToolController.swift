import MCP

/// Decodes and dispatches the one public read-only search tool.
struct SearchToolController: Sendable {
    private let search: any VaultSearchService

    init(search: any VaultSearchService) {
        self.search = search
    }

    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        try Task.checkCancellation()
        guard params.name == SearchToolDefinition.name else {
            return SearchToolResultMapper.failure("Unknown tool: \(params.name)")
        }

        let request: VaultSearchRequest
        do {
            request = try SearchToolRequestDecoder.decode(params)
        } catch let error as SearchToolRequestDecoder.DecodingError {
            return SearchToolResultMapper.failure(error.description)
        } catch {
            return SearchToolResultMapper.failure("Invalid search request")
        }

        do {
            let response = try await search.search(request)
            try Task.checkCancellation()
            return try SearchToolResultMapper.success(response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VaultSearchRequestError {
            try Task.checkCancellation()
            return SearchToolResultMapper.failure(error.description)
        } catch {
            try Task.checkCancellation()
            return SearchToolResultMapper.failure("Search failed safely")
        }
    }
}
