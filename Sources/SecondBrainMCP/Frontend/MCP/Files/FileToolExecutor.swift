/// Executes decoded file requests through the shared CRUD service boundary.
///
/// Cancellation is allowed to propagate to the backend and MCP transport. Native
/// framework calls that do not observe cancellation are not wrapped in a false
/// structured-concurrency deadline: leaving a task group still waits for them,
/// while abandoning mutation work could let it write after reporting a timeout.
struct FileToolExecutor: Sendable {
    private let files: any FileCRUDService

    /// Creates an executor over one initialized file service.
    ///
    /// - Parameter files: Shared CRUD service implementation.
    init(files: any FileCRUDService) {
        self.files = files
    }

    /// Routes a decoded request to its matching CRUD operation.
    ///
    /// - Parameter request: Decoded file tool request.
    /// - Returns: Transport-neutral operation output.
    func execute(_ request: FileToolRequest) async throws -> FileOperationOutput {
        switch request {
        case .create(let request):
            try await files.create(request)
        case .read(let request):
            try await files.read(request)
        case .update(let request):
            try await files.update(request)
        case .delete(let request):
            try await files.delete(request)
        }
    }
}
