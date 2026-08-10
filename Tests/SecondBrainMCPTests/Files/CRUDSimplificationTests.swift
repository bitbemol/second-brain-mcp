import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct `CRUD simplification` {
    private func makeRuntime() async throws -> (root: String, runtime: VaultRuntime) {
        let root = NSTemporaryDirectory() + "CRUDSimplificationTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        return (root, try await VaultRuntime.bootstrap(vaultPath: root))
    }

    @Test
    func `Structured text reads return only the stored atomic content`() async throws {
        let (_, runtime) = try await makeRuntime()
        let cases: [(FileFormat, String, String)] = [
            (
                .canvas,
                "notes/board.canvas",
                #"{"nodes":[],"edges":[]}"#
            ),
            (
                .patch,
                "notes/change.patch",
                """
                diff --git a/file.txt b/file.txt
                --- a/file.txt
                +++ b/file.txt
                @@ -1 +1 @@
                -old
                +new
                """
            ),
        ]

        for (format, path, content) in cases {
            _ = try await runtime.files.create(CreateFileRequest(
                format: format,
                path: path,
                content: content,
                source: nil,
                tags: [],
                transform: nil
            ))
            let output = try await runtime.files.read(ReadFileRequest(
                format: format,
                path: path,
                options: .default
            ))

            #expect(try text(from: output) == content)
        }
    }

    @Test
    func `HAR reads return sanitized atomic JSON by default`() async throws {
        let (_, runtime) = try await makeRuntime()
        let secret = "Bearer " + String(repeating: "s", count: 32)
        let content = """
        {"log":{"version":"1.2","creator":{"name":"Test"},"entries":[
          {"request":{"method":"GET","url":"https://example.com",
           "headers":[{"name":"Authorization","value":"\(secret)"}]},
           "response":{"status":200},"time":1}
        ]}}
        """
        _ = try await runtime.files.create(CreateFileRequest(
            format: .har,
            path: "notes/capture.har",
            content: content,
            source: nil,
            tags: [],
            transform: nil
        ))

        let output = try await runtime.files.read(ReadFileRequest(
            format: .har,
            path: "notes/capture.har",
            options: .default
        ))
        let returned = try text(from: output)

        #expect(!returned.contains(secret))
        #expect(returned.contains(HARSensitiveDataSanitizer.redactionMarker))
        #expect(try JSONSerialization.jsonObject(with: Data(returned.utf8)) is [String: Any])
    }

    @Test
    func `Tool discovery derives create inputs and update modes from format contracts`() async throws {
        let (_, runtime) = try await makeRuntime()
        let tools = FileToolDefinitions.build(
            capabilities: runtime.capabilities,
            readOnly: false
        )
        let create = try #require(tools.first { $0.name == FileToolName.create.rawValue })
        let update = try #require(tools.first { $0.name == FileToolName.update.rawValue })

        let createProperties = try properties(of: create)
        let createFormat = try #require(
            createProperties[FileToolArgument.format.rawValue]?.objectValue
        )
        let createDescription = try #require(
            createFormat["description"]?.stringValue
        )
        #expect(createDescription.contains("har=content"))
        #expect(createDescription.contains("png=source"))
        #expect(createDescription.contains("gif=source+video_to_gif"))

        let updateProperties = try properties(of: update)
        let mode = try #require(
            updateProperties[FileToolArgument.mode.rawValue]?.objectValue
        )
        let modeDescription = try #require(mode["description"]?.stringValue)
        #expect(modeDescription.contains("canvas=replace"))
        #expect(modeDescription.contains("log=append"))
        #expect(modeDescription.contains("json=patch|replace"))
    }

    private func text(from output: FileOperationOutput) throws -> String {
        guard case .text(let value) = output.contents.first else {
            throw ExpectedText()
        }
        return value
    }

    private func properties(of tool: Tool) throws -> [String: Value] {
        let schema = try #require(tool.inputSchema.objectValue)
        return try #require(schema["properties"]?.objectValue)
    }

    private struct ExpectedText: Error {}
}
