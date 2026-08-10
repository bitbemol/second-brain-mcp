import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct `MCP directory move contract` {
    private actor ServiceSpy: DirectoryMoveService {
        var requests: [MoveDirectoryRequest] = []

        func move(_ request: MoveDirectoryRequest) async throws -> FileOperationOutput {
            requests.append(request)
            return FileOperationOutput.text("moved").withMetadata(FileOperationMetadata(
                path: request.destinationPath,
                sourcePath: request.sourcePath,
                area: .notes,
                revision: nil,
                mutationID: request.mutationID,
                replayed: false
            ))
        }

        func lastRequest() -> MoveDirectoryRequest? { requests.last }
    }

    @Test
    func `Schema describes one closed replay-safe recursive move`() throws {
        let tool = try #require(DirectoryMoveToolDefinition.build(readOnly: false))
        #expect(tool.name == "move_directory")
        #expect(tool.annotations.idempotentHint == true)
        #expect(tool.annotations.destructiveHint == true)
        #expect(tool.description?.contains("path_prefix") != true)
        #expect(tool.description?.contains("does not take a file format") == true)
        let input = try #require(tool.inputSchema.objectValue)
        let required = Set(try #require(input["required"]?.arrayValue).compactMap(\.stringValue))
        #expect(required == ["mutation_id", "source_path", "destination_path"])
        #expect(input["additionalProperties"]?.boolValue == false)
        let properties = try #require(input["properties"]?.objectValue)
        #expect(properties["source_path"]?.objectValue?["maxLength"]?.intValue
            == DirectoryMoveRequestLimits.maximumPathBytes)

        let output = try #require(tool.outputSchema?.objectValue)
        let outputRequired = Set(
            try #require(output["required"]?.arrayValue).compactMap(\.stringValue)
        )
        #expect(outputRequired == [
            "source_path", "destination_path", "mutation_id", "replayed",
        ])
        #expect(DirectoryMoveToolDefinition.build(readOnly: true) == nil)
    }

    @Test
    func `Controller strictly decodes and routes canonical request values`() async throws {
        let service = ServiceSpy()
        let controller = DirectoryMoveToolController(
            readOnly: false,
            directories: service
        )
        let mutation = MutationID()
        let result = try await controller.call(.init(
            name: "move_directory",
            arguments: [
                "mutation_id": .string(mutation.rawValue),
                "source_path": .string("notes/in-progress/ticket-123"),
                "destination_path": .string("notes/completed/ticket-123"),
            ]
        ))
        #expect(result.isError != true)
        #expect(await service.lastRequest() == MoveDirectoryRequest(
            mutationID: mutation,
            sourcePath: "notes/in-progress/ticket-123",
            destinationPath: "notes/completed/ticket-123"
        ))
        let structured = try #require(result.structuredContent?.objectValue)
        #expect(Set(structured.keys) == [
            "source_path", "destination_path", "mutation_id", "replayed",
        ])
        #expect(structured["source_path"]?.stringValue == "notes/in-progress/ticket-123")
        #expect(structured["destination_path"]?.stringValue
            == "notes/completed/ticket-123")
    }

    @Test
    func `Unknown arguments and read-only mutations are rejected before service`() async throws {
        let service = ServiceSpy()
        let readOnly = DirectoryMoveToolController(
            readOnly: true,
            directories: service
        )
        let blocked = try await readOnly.call(.init(
            name: "move_directory",
            arguments: ["source_path": .string("notes/work")]
        ))
        #expect(blocked.isError == true)
        #expect(await service.lastRequest() == nil)

        let writable = DirectoryMoveToolController(
            readOnly: false,
            directories: service
        )
        let invalid = try await writable.call(.init(
            name: "move_directory",
            arguments: [
                "mutation_id": .string(MutationID().rawValue),
                "source_path": .string("notes/work"),
                "destination_path": .string("notes/done/work"),
                "unexpected": .bool(true),
            ]
        ))
        #expect(invalid.isError == true)
        #expect(await service.lastRequest() == nil)
    }
}
