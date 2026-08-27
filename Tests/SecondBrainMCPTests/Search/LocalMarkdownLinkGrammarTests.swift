import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite("Local Markdown link grammar")
struct LocalMarkdownLinkGrammarTests {
    @Test("Escaped delimiters and code examples do not become graph edges")
    func excludesEscapesAndCode() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            "[[Real]]\n\\[[Escaped]]\n" +
            "`[[Inline]]`\n```markdown\n[[Fenced]]\n```\n",
            to: "notes/project/Source.md", root: root
        )
        let output = try await outgoing(root)
        #expect(targets(output) == ["Real"])
        #expect(output["coverage"]?.objectValue?["complete"]?.boolValue == true)
    }

    @Test("Inline local links retain raw destinations and resolve using source-relative paths")
    func resolvesInlinePathsAndFragments() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("# Target", to: "notes/Target.md", root: root)
        try write("pdf namespace fixture", to: "references/Book.pdf", root: root)
        try write(
            "[relative](../Target.md#Heading) ![book](../../references/Book.pdf) [self](#Here)",
            to: "notes/project/Source.md", root: root
        )
        let output = try await outgoing(root)
        let results = try #require(output["results"]?.arrayValue).compactMap(\.objectValue)
        #expect(results.compactMap { $0["target"]?.stringValue } == [
            "../Target.md#Heading", "../../references/Book.pdf", "#Here",
        ])
        #expect(results.compactMap { $0["resolved_path"]?.stringValue } == [
            "notes/Target.md", "references/Book.pdf", "notes/project/Source.md",
        ])
        #expect(results.compactMap { $0["resolved_format"]?.stringValue } == [
            "markdown", "pdf", "markdown",
        ])
        #expect(results.compactMap { $0["kind"]?.stringValue } == ["link", "embed", "link"])
        #expect(results.first?["fragment"]?.stringValue == "Heading")
        #expect(results.last?["fragment"]?.stringValue == "Here")
    }

    @Test("URI decoding happens once and cannot turn external or escaped paths into vault access")
    func decodesDestinationsOnce() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("# Target", to: "notes/Target.md", root: root)
        try write("# Hash", to: "notes/A#B.md", root: root)
        try write(
            "[hash](../A%23B.md?ignored=1#Part) [parent](%2e%2e/Target.md) " +
            "[outside](../../outside.md) [double](%252e%252e/Target.md) " +
            "[external](%66ile:///tmp/private.md) [https](https://example.test)",
            to: "notes/project/Source.md", root: root
        )
        let output = try await outgoing(root)
        let results = try #require(output["results"]?.arrayValue).compactMap(\.objectValue)
        #expect(results.count == 4)
        #expect(results.first?["resolved_path"]?.stringValue == "notes/A#B.md")
        #expect(results.dropFirst().first?["resolved_path"]?.stringValue == "notes/Target.md")
        #expect(results.dropFirst(2).allSatisfy { $0["resolved_path"] == nil })
        #expect(output["coverage"]?.objectValue?["complete"]?.boolValue == true)
    }

    @Test("Oversized identifiers mark the source incomplete and discard provisional edges")
    func oversizedTargetInvalidatesOnlyItsSource() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("# Target", to: "notes/Target.md", root: root)
        try write(
            "[[Target]] [[" + String(repeating: "x", count: 1_025) + "]]",
            to: "notes/project/Source.md", root: root
        )
        let output = try await outgoing(root)
        #expect(output["results"]?.arrayValue?.isEmpty == true)
        #expect(output["coverage"]?.objectValue?["complete"]?.boolValue == false)
        #expect(output["coverage"]?.objectValue?["failed_files"]?.intValue == 1)
        #expect(output["coverage"]?.objectValue?["samples"]?.arrayValue?.first?
            .objectValue?["reason"]?.stringValue == "file_limit")
    }

    @Test("Inline destinations support escaping, angle delimiters, and optional titles")
    func supportsInlineDestinationSyntax() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["notes/A(B).md", "notes/A B.md", "notes/Target.md"] {
            try write("# Target", to: path, root: root)
        }
        try write(
            #"[escaped](../A\(B\).md) [angle](<../A%20B.md>) [title](../Target.md "Title")"#,
            to: "notes/project/Source.md", root: root
        )
        let output = try await outgoing(root)
        let rows = try #require(output["results"]?.arrayValue).compactMap(\.objectValue)
        #expect(rows.compactMap { $0["target"]?.stringValue } == [
            #"../A\(B\).md"#, "../A%20B.md", "../Target.md",
        ])
        #expect(rows.compactMap { $0["resolved_path"]?.stringValue } == [
            "notes/A(B).md", "notes/A B.md", "notes/Target.md",
        ])
    }

    @Test("An unmatched label does not hide the following fenced-code boundary")
    func unmatchedLabelPreservesCodeBoundary() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        for prefix in ["[unterminated\n", "\\\n"] {
            try write(
                prefix + "~~~\n[[Hidden]]\n~~~\n[[Visible]]",
                to: "notes/project/Source.md", root: root
            )
            let output = try await outgoing(root)
            #expect(targets(output) == ["Visible"])
        }
    }

    @Test("Cancellation remains observable while escape sequences skip byte offsets")
    func cancellationDuringEscapedRun() async throws {
        let text = "[[First]]" + String(repeating: #"\x"#, count: 5_000) + "[[Second]]"
        let stopped = await Task.detached {
            var visits = 0
            do {
                try ObsidianWikiLinkParser.forEach(in: text) { _ in
                    visits += 1
                    if visits == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            } catch is CancellationError {
                return visits == 1
            } catch {
                return false
            }
            return false
        }.value
        #expect(stopped)
    }

    @Test("Unmatched prose and balanced nested labels preserve real local links")
    func nestedAndUnmatchedLabels() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("# Target", to: "notes/Target.md", root: root)
        try write(
            "[ordinary [[Target]]\n[a [b] c](../Target.md)",
            to: "notes/project/Source.md", root: root
        )
        let output = try await outgoing(root)
        let rows = try #require(output["results"]?.arrayValue).compactMap(\.objectValue)
        #expect(rows.compactMap { $0["resolved_path"]?.stringValue } == [
            "notes/Target.md", "notes/Target.md",
        ])
        #expect(rows.last?["alias"]?.stringValue == "a [b] c")
    }

    @Test("Wiki URLs are excluded without discarding literal colon filenames")
    func wikiURLsPreserveColonFilenames() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("# Meeting", to: "notes/Meeting:Notes.md", root: root)
        try write(
            "[[Meeting:Notes]] [[https://example.test]] [[MAILTO:person@example.test]] " +
            "[[file:/tmp/private]] [[javascript:alert]] [[data:text/plain,test]] " +
            "[[custom-scheme://host]] [custom](custom-scheme:opaque)",
            to: "notes/project/Source.md", root: root
        )
        let output = try await outgoing(root)
        #expect(targets(output) == ["Meeting:Notes"])
        #expect(output["results"]?.arrayValue?.first?.objectValue?["resolved_path"]?
            .stringValue == "notes/Meeting:Notes.md")
    }

    private func targets(_ output: [String: Value]) -> [String] {
        output["results"]?.arrayValue?.compactMap { $0.objectValue?["target"]?.stringValue } ?? []
    }

    private func outgoing(_ root: URL) async throws -> [String: Value] {
        let engine = VaultLinkQueryEngine(
            vaultPath: root.path,
            capabilities: FileCapabilities(formats: [
                .init(format: .markdown, operations: [.read: [.notes]]),
                .init(format: .pdf, operations: [.read: [.references]]),
            ]),
            store: VaultCRUDStore(vaultPath: root.path),
            access: VaultAccessCoordinator(lockURL: root.appendingPathComponent(".vault-access.lock"))
        )
        let result = try await LinkQueryToolController(links: engine).call(.init(
            name: "query_links",
            arguments: ["direction": .string("outgoing"), "target": .string("notes/project/Source.md")]
        ))
        #expect(result.isError != true)
        return try #require(result.structuredContent?.objectValue)
    }

    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMarkdownLinkGrammarTests-\(UUID().uuidString)")
        for directory in ["notes/project", "references"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true
            )
        }
        return root
    }

    private func write(_ text: String, to path: String, root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }
}
