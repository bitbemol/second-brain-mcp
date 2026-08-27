import MCP
import Testing
@testable import second_brain_mcp

@Suite("MCP boundary validation")
struct MCPBoundaryValidationTests {
    private let revision = "sha256:" + String(repeating: "a", count: 64)

    @Test("Unknown nested patch fields are rejected before calling the file service")
    func rejectsUnknownReplacementFields() async throws {
        let service = ServiceSpy()
        let controller = FileToolController(readOnly: false, files: service)
        let result = try await controller.call(.init(
            name: "update_file",
            arguments: [
                "format": .string("markdown"), "path": .string("notes/demo.md"),
                "expected_revision": .string(revision), "mode": .string("patch"),
                "replacements": .array([.object([
                    "old_text": .string("before"), "new_text": .string("after"),
                    "case_sensitive": .bool(false),
                ])]),
            ]
        ))
        #expect(result.isError == true)
        #expect(await service.callCount() == 0)
    }

    @Test("Invalid argument errors stay bounded and never echo arbitrary input")
    func boundedNonEchoingArgumentErrors() async throws {
        let service = ServiceSpy()
        let controller = FileToolController(readOnly: false, files: service)
        let marker = "PRIVATE_INPUT_MARKER"
        let untrusted = marker + String(repeating: "x", count: 8_192)
        let inputs: [CallTool.Parameters] = [
            .init(name: untrusted),
            .init(name: "read_file", arguments: [
                "format": .string(untrusted), "path": .string("notes/demo.md"),
            ]),
            .init(name: "read_file", arguments: [
                "format": .string("markdown"), "path": .string("notes/demo.md"),
                "view": .string(untrusted),
            ]),
            .init(name: "update_file", arguments: [
                "format": .string("markdown"), "path": .string("notes/demo.md"),
                "expected_revision": .string(revision), "mode": .string(untrusted),
            ]),
            .init(name: "create_file", arguments: [
                "format": .string("gif"), "path": .string("notes/demo.gif"),
                "source": .string("/tmp/demo.mov"), "transform": .string(untrusted),
            ]),
            .init(name: "read_file", arguments: [
                "format": .string("markdown"), "path": .string("notes/demo.md"),
                untrusted: .bool(true),
            ]),
        ]
        for input in inputs {
            let result = try await controller.call(input)
            let message = result.content.compactMap { content -> String? in
                if case .text(let text, _, _) = content { return text }
                return nil
            }.joined()
            #expect(result.isError == true)
            #expect(!message.isEmpty)
            #expect(message.utf8.count <= 512)
            #expect(!message.contains(marker))
        }
        #expect(await service.callCount() == 0)
    }

    @Test("Patch schema exposes bounded strict replacement objects")
    func patchSchemaMatchesRuntimeBounds() throws {
        let capabilities = FileCapabilities(formats: [
            .init(format: .markdown, operations: [.update: [.notes]]),
        ])
        let tool = try #require(FileToolDefinitions.build(
            capabilities: capabilities, readOnly: false
        ).first { $0.name == "update_file" })
        let replacements = try #require(tool.inputSchema.objectValue?["properties"]?
            .objectValue?["replacements"]?.objectValue)
        #expect(replacements["maxItems"]?.intValue == 20)
        #expect(replacements["items"]?.objectValue?["additionalProperties"]?.boolValue == false)
    }

    @Test("Update modes reject fields belonging to a different mutation mode")
    func rejectsMixedUpdateModeFields() async throws {
        for mode in ["replace", "append", "patch"] {
            let service = ServiceSpy()
            let result = try await FileToolController(readOnly: false, files: service).call(.init(
                name: "update_file",
                arguments: [
                    "format": .string("markdown"), "path": .string("notes/demo.md"),
                    "expected_revision": .string(revision), "mode": .string(mode),
                    "content": .string("replacement"),
                    "replacements": .array([.object([
                        "old_text": .string("before"), "new_text": .string("after"),
                    ])]),
                ]
            ))
            #expect(result.isError == true)
            #expect(await service.callCount() == 0)
        }
    }

    private actor ServiceSpy: FileCRUDService {
        private var calls = 0

        func callCount() -> Int { calls }

        func create(_ request: CreateFileRequest) async throws -> FileOperationOutput {
            calls += 1
            return .text("created")
        }

        func read(_ request: ReadFileRequest) async throws -> FileOperationOutput {
            calls += 1
            return .text("read")
        }

        func update(_ request: UpdateFileRequest) async throws -> FileOperationOutput {
            calls += 1
            return .text("updated")
        }

        func delete(_ request: DeleteFileRequest) async throws -> FileOperationOutput {
            calls += 1
            return .text("deleted")
        }
    }
}
