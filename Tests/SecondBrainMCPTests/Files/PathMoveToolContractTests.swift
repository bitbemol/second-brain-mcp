import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct `MCP path move contract` {
    private actor ServiceSpy: PathMoveService {
        var requests: [MovePathRequest] = []

        func move(_ request: MovePathRequest) async throws -> FileOperationOutput {
            requests.append(request)
            return FileOperationOutput.text("moved").withMetadata(FileOperationMetadata(
                path: request.destinationPath,
                sourcePath: request.sourcePath,
                area: .notes,
                revision: nil
            ))
        }

        func allRequests() -> [MovePathRequest] { requests }
    }

    private actor PathLeakingService: PathMoveService {
        func move(_ request: MovePathRequest) async throws -> FileOperationOutput {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSFilePathErrorKey: leakedMoveAbsolutePath]
            )
        }
    }

    private actor CallerSafeFailingService: PathMoveService {
        func move(_ request: MovePathRequest) async throws -> FileOperationOutput {
            throw PathMoveError.destinationExists(request.destinationPath)
        }
    }

    private let capabilities = FileCapabilities(formats: [
        .init(
            format: .markdown,
            operations: [.read: [.notes], .update: [.notes], .delete: [.notes]]
        ),
        .init(format: .jpeg, operations: [.read: [.notes], .delete: [.notes]]),
        .init(format: .pdf, operations: [.read: [.references]]),
    ])

    @Test
    func `Schema discriminates file revision inputs from directory moves`() throws {
        let tool = try #require(PathMoveToolDefinition.build(
            readOnly: false,
            capabilities: capabilities
        ))
        #expect(tool.name == "move_path")
        #expect(tool.annotations.idempotentHint == false)
        #expect(tool.annotations.destructiveHint == true)
        #expect(tool.description?.contains("read-create-delete") == true)
        #expect(tool.description?.contains("does not batch") == true)

        let input = try #require(tool.inputSchema.objectValue)
        let variants = try #require(input["oneOf"]?.arrayValue)
        #expect(variants.count == 2)
        let file = try #require(variants.first {
            $0.objectValue?["properties"]?.objectValue?["kind"]?
                .objectValue?["const"]?.stringValue == "file"
        }?.objectValue)
        let directory = try #require(variants.first {
            $0.objectValue?["properties"]?.objectValue?["kind"]?
                .objectValue?["const"]?.stringValue == "directory"
        }?.objectValue)

        let fileRequired = Set(
            try #require(file["required"]?.arrayValue).compactMap(\.stringValue)
        )
        #expect(fileRequired == [
            "kind", "source_path", "destination_path", "format", "expected_revision",
        ])
        let fileProperties = try #require(file["properties"]?.objectValue)
        let formats = try #require(
            fileProperties["format"]?.objectValue?["enum"]?.arrayValue
        ).compactMap(\.stringValue)
        #expect(formats == ["jpeg", "markdown"])
        #expect(file["additionalProperties"]?.boolValue == false)

        let directoryRequired = Set(
            try #require(directory["required"]?.arrayValue).compactMap(\.stringValue)
        )
        #expect(directoryRequired == ["kind", "source_path", "destination_path"])
        let directoryProperties = try #require(directory["properties"]?.objectValue)
        #expect(Set(directoryProperties.keys) == [
            "kind", "source_path", "destination_path",
        ])
        #expect(directory["additionalProperties"]?.boolValue == false)
        #expect(PathMoveToolDefinition.build(
            readOnly: true,
            capabilities: capabilities
        ) == nil)
    }

    @Test
    func `Controller routes typed file and directory requests`() async throws {
        let service = ServiceSpy()
        let controller = PathMoveToolController(readOnly: false, paths: service)
        let revision = FileSnapshot(
            data: Data("original".utf8),
            modifiedDate: nil
        ).revision
        let fileResult = try await controller.call(.init(
            name: "move_path",
            arguments: [
                "kind": .string("file"),
                "source_path": .string("notes/in-progress/overview.md"),
                "destination_path": .string("notes/completed/overview.md"),
                "format": .string("markdown"),
                "expected_revision": .string(revision.rawValue),
            ]
        ))
        let directoryResult = try await controller.call(.init(
            name: "move_path",
            arguments: [
                "kind": .string("directory"),
                "source_path": .string("notes/in-progress/ticket-123"),
                "destination_path": .string("notes/completed/ticket-123"),
            ]
        ))

        #expect(fileResult.isError != true)
        #expect(directoryResult.isError != true)
        #expect(await service.allRequests() == [
            .file(
                sourcePath: "notes/in-progress/overview.md",
                destinationPath: "notes/completed/overview.md",
                format: .markdown,
                expectedRevision: revision
            ),
            .directory(
                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ),
        ])
        let structured = try #require(fileResult.structuredContent?.objectValue)
        #expect(structured["source_path"]?.stringValue
            == "notes/in-progress/overview.md")
        #expect(structured["destination_path"]?.stringValue
            == "notes/completed/overview.md")
    }

    @Test
    func `Controller rejects mixed variants unknown inputs and read-only calls`() async throws {
        let service = ServiceSpy()
        let writable = PathMoveToolController(readOnly: false, paths: service)
        let mixed = try await writable.call(.init(
            name: "move_path",
            arguments: [
                "kind": .string("directory"),
                "source_path": .string("notes/work"),
                "destination_path": .string("notes/done/work"),
                "format": .string("markdown"),
            ]
        ))
        let missingRevision = try await writable.call(.init(
            name: "move_path",
            arguments: [
                "kind": .string("file"),
                "source_path": .string("notes/work.md"),
                "destination_path": .string("notes/done.md"),
                "format": .string("markdown"),
            ]
        ))
        let unknown = try await writable.call(.init(
            name: "move_path",
            arguments: [
                "kind": .string("directory"),
                "source_path": .string("notes/work"),
                "destination_path": .string("notes/done/work"),
                "unexpected": .bool(true),
            ]
        ))
        let readOnly = PathMoveToolController(readOnly: true, paths: service)
        let blocked = try await readOnly.call(.init(
            name: "move_path",
            arguments: [
                "kind": .string("directory"),
                "source_path": .string("notes/work"),
                "destination_path": .string("notes/done/work"),
            ]
        ))

        #expect(mixed.isError == true)
        #expect(missingRevision.isError == true)
        #expect(unknown.isError == true)
        #expect(blocked.isError == true)
        #expect(await service.allRequests().isEmpty)
    }

    @Test
    func `Unexpected move failures do not disclose absolute filesystem paths`() async throws {
        let controller = PathMoveToolController(
            readOnly: false,
            paths: PathLeakingService()
        )
        let result = try await controller.call(.init(
            name: "move_path",
            arguments: [
                "kind": .string("directory"),
                "source_path": .string("notes/work"),
                "destination_path": .string("notes/done/work"),
            ]
        ))

        let message = firstText(in: result)
        #expect(result.isError == true)
        #expect(message == "Path move failed due to an internal error")
        #expect(message?.contains(leakedMoveAbsolutePath) == false)
    }

    @Test
    func `Caller-safe move failures remain actionable`() async throws {
        let controller = PathMoveToolController(
            readOnly: false,
            paths: CallerSafeFailingService()
        )
        let result = try await controller.call(.init(
            name: "move_path",
            arguments: [
                "kind": .string("directory"),
                "source_path": .string("notes/work"),
                "destination_path": .string("notes/done/work"),
            ]
        ))

        #expect(result.isError == true)
        #expect(firstText(in: result) == "Error: Destination already exists: notes/done/work")
    }

    private func firstText(in result: CallTool.Result) -> String? {
        guard let first = result.content.first,
              case .text(let text, _, _) = first else {
            return nil
        }
        return text
    }
}

private let leakedMoveAbsolutePath = "/Users/private/Vault/notes/done/work"
