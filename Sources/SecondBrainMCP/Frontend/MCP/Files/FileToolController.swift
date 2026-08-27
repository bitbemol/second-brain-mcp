import MCP

/// Translates and dispatches the four MCP file tools to the backend service.
///
/// The controller owns boundary orchestration and read-only rejection. Dedicated
/// collaborators own decoding, execution policy, and MCP result conversion.
struct FileToolController: Sendable {
    private let readOnly: Bool
    private let executor: FileToolExecutor

    /// Creates a controller for one initialized vault runtime.
    init(
        readOnly: Bool,
        files: any FileCRUDService
    ) {
        self.readOnly = readOnly
        self.executor = FileToolExecutor(files: files)
    }

    /// Dispatches an MCP tool call or returns a transport-level error result.
    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        try Task.checkCancellation()
        guard let tool = FileToolName(rawValue: params.name) else {
            try Task.checkCancellation()
            return ToolFailureProjection.rejected("Unknown tool: choose a tool returned by tools/list")
        }

        if readOnly, tool.operation.isMutation {
            try Task.checkCancellation()
            return ToolFailureProjection.rejected(
                "Server is running in read-only mode; '\(params.name)' is not permitted."
            )
        }

        let request: FileToolRequest
        do {
            request = try FileToolRequestDecoder.decode(params, for: tool)
        } catch let error as FileToolRequestDecoder.DecodingError {
            try Task.checkCancellation()
            return ToolFailureProjection.rejected(error.description)
        } catch {
            try Task.checkCancellation()
            return ToolFailureProjection.operation(
                error, state: .notApplied,
                fallback: "File request could not be decoded due to an internal error"
            )
        }

        do {
            let output = try await executor.execute(request)
            try Task.checkCancellation()
            return FileToolResultMapper.success(output)
        } catch is CancellationError {
            // MCP suppresses a response only when cancellation escapes the handler.
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return ToolFailureProjection.operation(
                error, state: tool.operation.isMutation ? .unknown : .readOnly,
                fallback: "File operation failed due to an internal error"
            )
        }
    }

}
