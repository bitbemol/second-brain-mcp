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
    func `Schema exposes flat file and directory inputs with conditional guidance`() throws {
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
        #expect(input["oneOf"] == nil)
        let properties = try #require(input["properties"]?.objectValue)
        #expect(Set(properties.keys) == [
            "kind", "source_path", "destination_path", "format", "expected_revision",
        ])
        #expect(properties["kind"]?.objectValue?["enum"]?.arrayValue == [
            .string("file"), .string("directory"),
        ])
        let required = Set(try #require(input["required"]?.arrayValue).compactMap(\.stringValue))
        #expect(required == ["kind", "source_path", "destination_path"])
        let formats = try #require(properties["format"]?.objectValue?["enum"]?.arrayValue)
            .compactMap(\.stringValue)
        #expect(formats == ["jpeg", "markdown"])
        #expect(input["additionalProperties"]?.boolValue == false)
        for field in ["format", "expected_revision"] {
            let description = try #require(properties[field]?.objectValue?["description"]?.stringValue)
            #expect(description.contains("Required for kind=file"))
            #expect(description.contains("omit for kind=directory"))
        }
        #expect(PathMoveToolDefinition.build(
            readOnly: true,
            capabilities: capabilities
        ) == nil)
    }

    @Test
    func `Conditional move fields remain enforced before service dispatch`() async throws {
        let service = ServiceSpy()
        let controller = PathMoveToolController(readOnly: false, paths: service)
        let revision = "sha256:" + String(repeating: "a", count: 64)
        let cases: [[String: Value]] = [
            ["kind": .string("file")],
            ["kind": .string("file"), "format": .string("markdown")],
            ["kind": .string("file"), "expected_revision": .string(revision)],
            ["kind": .string("directory"), "format": .string("markdown")],
            ["kind": .string("directory"), "expected_revision": .string(revision)],
            ["kind": .string("directory"), "format": .null],
            ["kind": .string("file"), "format": .string("markdown"), "expected_revision": .null],
        ]
        for fields in cases {
            var arguments = fields
            arguments["source_path"] = .string("notes/source.md")
            arguments["destination_path"] = .string("notes/destination.md")
            let result = try await controller.call(.init(name: "move_path", arguments: arguments))
            #expect(result.isError == true)
            #expect(result.structuredContent?.objectValue?["error"]?.objectValue?["state"]
                == .string("not_applied"))
        }
        #expect(await service.allRequests().isEmpty)
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
        #expect(message == "Path move failed due to an internal error Outcome unconfirmed; inspect current state before retrying.")
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
        #expect(firstText(in: result) == "Error: Destination already exists: notes/done/work Outcome unconfirmed; inspect current state before retrying.")
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
