import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct `Scoped search contract` {
    private final class Opens: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ path: String) { lock.withLock { paths.append(path) } }
        var values: [String] { lock.withLock { paths } }
    }

    @Test
    func `Directory and format scope exclude unrelated content before opening`() async throws {
        let root = try vault()
        defer { removeSearchFixture(root) }
        try write("needle", "notes/project/a.md", root)
        try write("{\"needle\":true}", "notes/project/b.json", root)
        try write("needle", "notes/unrelated.md", root)
        let opens = Opens()
        let result = try await controller(root, opens: opens).call(.init(
            name: "search_vault", arguments: [
                "location": .string("notes"), "query": .string("needle"),
                "directory": .string("project"), "formats": .array([.string("markdown")]),
            ]
        ))
        #expect(result.isError != true)
        let values = try #require(result.structuredContent?.objectValue)
        #expect(values["results"]?.arrayValue?.count == 1)
        #expect(values["results"]?.arrayValue?.first?.objectValue?["path"]?.stringValue
            == "notes/project/a.md")
        #expect(opens.values == ["notes/project/a.md"])
    }

    @Test
    func `Metadata queries never open formats that cannot match metadata`() async throws {
        let root = try vault()
        defer { removeSearchFixture(root) }
        try write("---\ntags: [swift]\n---\nneedle", "notes/a.md", root)
        try write("{\"needle\":true}", "notes/b.json", root)
        let opens = Opens()
        let result = try await controller(root, opens: opens).call(.init(
            name: "search_vault", arguments: [
                "location": .string("notes"), "tags": .array([.string("swift")]),
            ]
        ))
        #expect(result.isError != true)
        #expect(opens.values == ["notes/a.md"])
    }

    @Test
    func `Coverage is identical in structured and fallback responses and advertised by schema`() async throws {
        let root = try vault()
        defer { removeSearchFixture(root) }
        try write("needle", "notes/a.md", root)
        try Data([0xff]).write(to: root.appendingPathComponent("notes/b.md"))
        let result = try await controller(root, opens: Opens()).call(.init(
            name: "search_vault", arguments: [
                "location": .string("notes"), "query": .string("needle"),
            ]
        ))
        let coverage = try #require(result.structuredContent?.objectValue?["coverage"]?.objectValue)
        #expect(coverage["complete"]?.boolValue == false)
        #expect(coverage["failed_files"]?.intValue == 1)
        guard case .text(let text, _, _) = result.content.first else {
            Issue.record("Expected fallback JSON")
            return
        }
        let fallback = try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        #expect(fallback == result.structuredContent)
        let output = try #require(SearchToolDefinition.build().outputSchema?.objectValue)
        #expect(output["required"]?.arrayValue?.contains(.string("coverage")) == true)
        #expect(output["properties"]?.objectValue?["coverage"] != nil)
    }

    @Test
    func `Explicit unsafe hidden missing and file directories never appear complete`() async throws {
        let root = try vault()
        defer { removeSearchFixture(root) }
        try write("needle", "notes/a.md", root)
        try write("needle", "notes/.private/a.md", root)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("notes/alias").path,
            withDestinationPath: root.appendingPathComponent("notes/.private").path
        )
        for directory in ["../references", ".private", "alias", "absent", "a.md"] {
            let result = try await controller(root, opens: Opens()).call(.init(
                name: "search_vault", arguments: [
                    "location": .string("notes"), "query": .string("needle"),
                    "directory": .string(directory),
                ]
            ))
            #expect(result.isError == true)
        }
    }

    private func vault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchScopeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"), withIntermediateDirectories: true
        )
        return root
    }

    private func write(_ text: String, _ path: String, _ root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func controller(_ root: URL, opens: Opens) -> SearchToolController {
        let capture = searchCaptureFixture(root) { opens.record($0.relativePath) }
        return SearchToolController(search: VaultSearchEngine(source: SearchCorpusBuilder(
            vaultPath: root.path,
            capabilities: FileCapabilities(formats: [
                .init(format: .markdown, operations: [.read: [.notes]]),
                .init(format: .json, operations: [.read: [.notes]]),
            ]),
            captureStore: capture,
            access: VaultAccessCoordinator(lockURL: root.appendingPathComponent(".vault-access.lock"))
        )))
    }
}
