import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct `MCP file tool controller` {

    private actor FileServiceSpy: FileCRUDService {
        private var calls = 0
        private var createRequests: [CreateFileRequest] = []

        func create(_ request: CreateFileRequest) async throws -> FileOperationOutput {
            calls += 1
            createRequests.append(request)
            return .text("created by service spy")
        }

        func read(_ request: ReadFileRequest) async throws -> FileOperationOutput {
            calls += 1
            return .text("read by service spy")
        }

        func update(_ request: UpdateFileRequest) async throws -> FileOperationOutput {
            calls += 1
            return .text("updated by service spy")
        }

        func delete(_ request: DeleteFileRequest) async throws -> FileOperationOutput {
            calls += 1
            return .text("deleted by service spy")
        }

        func callCount() -> Int {
            calls
        }

        func lastCreateRequest() -> CreateFileRequest? {
            createRequests.last
        }
    }

    private actor CancellingFileService: FileCRUDService {
        func create(_ request: CreateFileRequest) async throws -> FileOperationOutput {
            throw CancellationError()
        }

        func read(_ request: ReadFileRequest) async throws -> FileOperationOutput {
            throw CancellationError()
        }

        func update(_ request: UpdateFileRequest) async throws -> FileOperationOutput {
            throw CancellationError()
        }

        func delete(_ request: DeleteFileRequest) async throws -> FileOperationOutput {
            throw CancellationError()
        }
    }

    private actor SelfCancellingFileService: FileCRUDService {
        private func cancelAndReturn() -> FileOperationOutput {
            withUnsafeCurrentTask { $0?.cancel() }
            return .text("must not escape as success")
        }

        func create(_ request: CreateFileRequest) async throws -> FileOperationOutput {
            cancelAndReturn()
        }

        func read(_ request: ReadFileRequest) async throws -> FileOperationOutput {
            cancelAndReturn()
        }

        func update(_ request: UpdateFileRequest) async throws -> FileOperationOutput {
            cancelAndReturn()
        }

        func delete(_ request: DeleteFileRequest) async throws -> FileOperationOutput {
            cancelAndReturn()
        }
    }

    private actor CancelThenFailFileService: FileCRUDService {
        private func cancelAndFail() throws -> FileOperationOutput {
            withUnsafeCurrentTask { $0?.cancel() }
            throw ControllerTestError.expected
        }

        func create(_ request: CreateFileRequest) async throws -> FileOperationOutput {
            try cancelAndFail()
        }

        func read(_ request: ReadFileRequest) async throws -> FileOperationOutput {
            try cancelAndFail()
        }

        func update(_ request: UpdateFileRequest) async throws -> FileOperationOutput {
            try cancelAndFail()
        }

        func delete(_ request: DeleteFileRequest) async throws -> FileOperationOutput {
            try cancelAndFail()
        }
    }

    private func makeController(
        readOnly: Bool
    ) -> (FileToolController, FileServiceSpy) {
        let files = FileServiceSpy()
        return (
            FileToolController(
                readOnly: readOnly,
                files: files
            ),
            files
        )
    }

    @Test
    func `Unknown tools fail at the MCP boundary`() async throws {
        let (controller, files) = makeController(readOnly: false)
        let result = try await controller.call(.init(name: "legacy_tool"))

        #expect(result.isError == true)
        #expect(firstText(in: result)?.contains("Unknown tool") == true)
        #expect(await files.callCount() == 0)
    }

    @Test
    func `Read-only mode rejects writes before routing`() async throws {
        let (controller, files) = makeController(readOnly: true)
        let result = try await controller.call(.init(
            name: "create_file",
            arguments: [
                "format": .string("markdown"),
                "path": .string("notes/blocked.md"),
                "content": .string("blocked"),
            ]
        ))

        #expect(result.isError == true)
        #expect(firstText(in: result)?.contains("read-only mode") == true)
        #expect(await files.callCount() == 0)
    }

    @Test
    func `Valid calls reach the shared file service boundary`() async throws {
        let (controller, files) = makeController(readOnly: false)
        let result = try await controller.call(.init(
            name: "create_file",
            arguments: [
                "format": .string("markdown"),
                "path": .string("notes/dispatched.md"),
                "content": .string("# Dispatched"),
            ]
        ))

        #expect(result.isError != true)
        #expect(firstText(in: result) == "created by service spy")
        let request = await files.lastCreateRequest()
        #expect(request?.format == .markdown)
        #expect(request?.path == "notes/dispatched.md")
        #expect(request?.content == "# Dispatched")
    }

    @Test
    func `Cancellation escapes so MCP can suppress the response`() async {
        let controller = FileToolController(
            readOnly: false,
            files: CancellingFileService()
        )

        await #expect(throws: CancellationError.self) {
            _ = try await controller.call(.init(
                name: "read_file",
                arguments: [
                    "format": .string("markdown"),
                    "path": .string("notes/cancelled.md"),
                ]
            ))
        }
    }

    @Test
    func `Cancellation observed by a synchronous backend cannot return success`() async {
        let controller = FileToolController(
            readOnly: false,
            files: SelfCancellingFileService()
        )
        let task = Task {
            try await controller.call(.init(
                name: "read_file",
                arguments: [
                    "format": .string("markdown"),
                    "path": .string("notes/cancelled.md"),
                ]
            ))
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func `Cancellation wins over ordinary backend errors`() async {
        let failingController = FileToolController(
            readOnly: false,
            files: CancelThenFailFileService()
        )
        let failureTask = Task {
            try await failingController.call(.init(
                name: "read_file",
                arguments: [
                    "format": .string("markdown"),
                    "path": .string("notes/cancelled.md"),
                ]
            ))
        }
        await #expect(throws: CancellationError.self) {
            _ = try await failureTask.value
        }
    }

    private func firstText(in result: CallTool.Result) -> String? {
        guard let first = result.content.first,
              case .text(let text, _, _) = first else {
            return nil
        }
        return text
    }
}

private enum ControllerTestError: Error {
    case expected
}
