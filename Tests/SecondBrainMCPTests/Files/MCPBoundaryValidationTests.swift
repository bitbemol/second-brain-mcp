import Foundation
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

    @Test("Canvas root-array errors show the object shape without supplied values")
    func canvasRootArrayExplainsObjectShape() throws {
        let marker = "PRIVATE_CANVAS_VALUE"
        do {
            _ = try CanvasDocumentValidator.decodeValidated(jsonData: Data("[\"\(marker)\"]".utf8))
            Issue.record("Canvas root arrays must remain invalid")
        } catch let error as any CallerSafeError {
            let message = error.callerSafeDescription
            #expect(message.contains("object"))
            #expect(message.contains(#"{"nodes":[],"edges":[]}"#))
            #expect(!message.contains(marker))
            #expect(message.utf8.count <= 512)
        }
        // The shape is an example, not a new requirement for present keys.
        let empty = try CanvasDocumentValidator.decodeValidated(jsonData: Data("{}".utf8))
        #expect(empty.nodes.isEmpty)
        #expect(empty.edges.isEmpty)
    }

    @Test("Area errors show an explicit vault-relative notes path without inferring it")
    func missingAreaPrefixExplainsExplicitPath() throws {
        do {
            _ = try VaultArea.resolve(path: "QA/PRIVATE_PATH_VALUE.md")
            Issue.record("An omitted area prefix must not be inferred")
        } catch let error as any CallerSafeError {
            let message = error.callerSafeDescription
            #expect(message.contains("vault-relative"))
            #expect(message.contains("notes/QA/example.md"))
            #expect(!message.contains("PRIVATE_PATH_VALUE"))
            #expect(message.utf8.count <= 512)
        }
        #expect(try VaultArea.resolve(path: "notes/QA/example.md") == .notes)
    }

    @Test("Create guidance distinguishes vault destinations from external media sources")
    func createGuidanceDistinguishesSourceAndDestination() throws {
        let capabilities = FileCapabilities(formats: [
            .init(format: .markdown, operations: [.create: [.notes], .read: [.notes]], createContract: .content),
            .init(format: .png, operations: [.create: [.notes]], createContract: .init(
                input: .source, transform: nil, acceptsTags: false
            )),
            .init(format: .gif, operations: [.create: [.notes]], createContract: .init(
                input: .source, transform: .videoToGIF, acceptsTags: false
            )),
        ])
        let tool = try #require(FileToolDefinitions.build(
            capabilities: capabilities, readOnly: false
        ).first { $0.name == "create_file" })
        let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
        let path = try #require(properties["path"]?.objectValue?["description"]?.stringValue)
        #expect(path.contains("vault-relative"))
        #expect(path.contains("notes/QA/example.md"))
        let source = try #require(properties["source"]?.objectValue?["description"]?.stringValue)
        #expect(source.contains("outside the vault"))
        #expect(source.contains("local file"))
        #expect(source.contains("data URI"))
        #expect(source.contains("png"))
        #expect(source.contains("image"))
        #expect(source.contains("gif"))
        #expect(source.contains("video_to_gif"))
        let read = try #require(FileToolDefinitions.build(
            capabilities: capabilities, readOnly: true
        ).first { $0.name == "read_file" })
        let maxBytes = try #require(read.inputSchema.objectValue?["properties"]?
            .objectValue?["max_bytes"]?.objectValue?["description"]?.stringValue)
        #expect(maxBytes.contains("Content only"))
        #expect(maxBytes.contains("omit for metadata"))
    }

    @Test("Search recovery guidance narrows scope and link targets exclude display aliases")
    func discoveryGuidanceExplainsRecoveryAndAliasIdentity() throws {
        let description = try #require(SearchToolDefinition.build(searchableFormats: FileFormat.allCases).description)
        let coverageAdvice = try #require(description.components(separatedBy: ". ").first {
            $0.contains("complete=false")
        })
        #expect(coverageAdvice.contains("directory"))
        #expect(coverageAdvice.contains("formats"))
        #expect(coverageAdvice.contains("absence"))
        let target = try #require(LinkQueryToolDefinition.build().inputSchema.objectValue?["properties"]?
            .objectValue?["target"]?.objectValue?["description"]?.stringValue)
        #expect(target.contains("alias"))
        #expect(target.contains("display"))
        #expect(target.contains("|"))
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
