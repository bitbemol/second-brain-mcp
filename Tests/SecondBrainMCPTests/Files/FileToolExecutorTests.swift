import Testing
@testable import SecondBrainMCP

@Suite("File tool executor")
struct FileToolExecutorTests {
    private actor ServiceSpy: FileCRUDService {
        private var operations: [FileCRUDOperation] = []

        func create(_ request: CreateFileRequest) async throws -> FileOperationOutput {
            operations.append(.create)
            return .text("create")
        }

        func read(_ request: ReadFileRequest) async throws -> FileOperationOutput {
            operations.append(.read)
            return .text("read")
        }

        func update(_ request: UpdateFileRequest) async throws -> FileOperationOutput {
            operations.append(.update)
            return .text("update")
        }

        func delete(_ request: DeleteFileRequest) async throws -> FileOperationOutput {
            operations.append(.delete)
            return .text("delete")
        }

        func recordedOperations() -> [FileCRUDOperation] {
            operations
        }
    }

    @Test("Decoded requests route to the matching CRUD operation")
    func routesRequests() async throws {
        let service = ServiceSpy()
        let executor = FileToolExecutor(files: service)

        _ = try await executor.execute(.create(CreateFileRequest(
            format: .markdown,
            path: "notes/page.md",
            content: "body",
            source: nil,
            tags: [],
            transform: nil
        )))
        _ = try await executor.execute(.read(ReadFileRequest(
            format: .markdown,
            path: "notes/page.md",
            options: .default
        )))
        _ = try await executor.execute(.update(UpdateFileRequest(
            format: .markdown,
            path: "notes/page.md",
            content: "updated",
            mode: .replace,
            replacements: []
        )))
        _ = try await executor.execute(.delete(DeleteFileRequest(
            format: .markdown,
            path: "notes/page.md"
        )))

        #expect(await service.recordedOperations() == FileCRUDOperation.allCases)
    }
}
