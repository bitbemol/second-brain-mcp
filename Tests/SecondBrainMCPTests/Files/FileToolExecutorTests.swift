import Testing
@testable import second_brain_mcp

@Suite
struct `File tool executor` {
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

    @Test
    func `Decoded requests route to the matching CRUD operation`() async throws {
        let service = ServiceSpy()
        let executor = FileToolExecutor(files: service)
        let revision = try #require(FileRevision(
            rawValue: "sha256:" + String(repeating: "a", count: 64)
        ))

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
            expectedRevision: revision,
            format: .markdown,
            path: "notes/page.md",
            content: "updated",
            mode: .replace,
            replacements: []
        )))
        _ = try await executor.execute(.delete(DeleteFileRequest(
            expectedRevision: revision,
            format: .markdown,
            path: "notes/page.md"
        )))

        #expect(await service.recordedOperations() == [
            .create, .read, .update, .delete,
        ])
    }
}
