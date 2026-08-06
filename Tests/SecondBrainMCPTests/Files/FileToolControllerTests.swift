import MCP
import Testing
@testable import SecondBrainMCP

@Suite("MCP file tool controller")
struct FileToolControllerTests {
    private let mutationID = "e7dc1f3a-5a20-41e9-91d8-3b9d289787b0"

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

    private actor RejectionSpy: FileRequestRejectionReporting {
        private var rejections: [FileRequestRejection] = []

        func record(_ rejection: FileRequestRejection) {
            rejections.append(rejection)
        }

        func recordedRejections() -> [FileRequestRejection] {
            rejections
        }
    }

    private actor SelfCancellingRejectionReporter: FileRequestRejectionReporting {
        func record(_ rejection: FileRequestRejection) {
            withUnsafeCurrentTask { $0?.cancel() }
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
    ) -> (FileToolController, FileServiceSpy, RejectionSpy) {
        let files = FileServiceSpy()
        let rejections = RejectionSpy()
        return (
            FileToolController(
                readOnly: readOnly,
                rejections: rejections,
                files: files
            ),
            files,
            rejections
        )
    }

    @Test("Unknown tools fail at the MCP boundary")
    func rejectsUnknownTool() async throws {
        let (controller, files, _) = makeController(readOnly: false)
        let result = try await controller.call(.init(name: "legacy_tool"))

        #expect(result.isError == true)
        #expect(firstText(in: result)?.contains("Unknown tool") == true)
        #expect(await files.callCount() == 0)
    }

    @Test("Read-only mode rejects writes before routing")
    func enforcesReadOnly() async throws {
        let (controller, files, rejections) = makeController(readOnly: true)
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
        let recorded = await rejections.recordedRejections()
        #expect(recorded == [FileRequestRejection(
            operation: .create,
            path: "notes/blocked.md",
            reason: .readOnly
        )])
    }

    @Test("Valid calls reach the shared file service boundary")
    func dispatchesCreate() async throws {
        let (controller, files, rejections) = makeController(readOnly: false)
        let result = try await controller.call(.init(
            name: "create_file",
            arguments: [
                "format": .string("markdown"),
                "path": .string("notes/dispatched.md"),
                "mutation_id": .string(mutationID),
                "content": .string("# Dispatched"),
            ]
        ))

        #expect(result.isError != true)
        #expect(firstText(in: result) == "created by service spy")
        let request = await files.lastCreateRequest()
        #expect(request?.format == .markdown)
        #expect(request?.path == "notes/dispatched.md")
        #expect(request?.mutationID.rawValue == mutationID)
        #expect(request?.content == "# Dispatched")
        #expect(await rejections.recordedRejections().isEmpty)
    }

    @Test("Cancellation escapes so MCP can suppress the response")
    func propagatesCancellation() async {
        let controller = FileToolController(
            readOnly: false,
            rejections: RejectionSpy(),
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

    @Test("Cancellation observed by a synchronous backend cannot return success")
    func checksCancellationAfterDispatch() async {
        let controller = FileToolController(
            readOnly: false,
            rejections: RejectionSpy(),
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

    @Test("Cancellation wins over rejection audit and ordinary backend errors")
    func cancellationWinsOverErrorMapping() async {
        let readOnlyController = FileToolController(
            readOnly: true,
            rejections: SelfCancellingRejectionReporter(),
            files: FileServiceSpy()
        )
        let rejectionTask = Task {
            try await readOnlyController.call(.init(
                name: "create_file",
                arguments: [
                    "format": .string("markdown"),
                    "path": .string("notes/cancelled.md"),
                    "content": .string("cancelled"),
                ]
            ))
        }
        await #expect(throws: CancellationError.self) {
            _ = try await rejectionTask.value
        }

        let failingController = FileToolController(
            readOnly: false,
            rejections: RejectionSpy(),
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
