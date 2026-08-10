import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Text search atom provider` {
    @Test
    func `Markdown uses the shared metadata parser and remains one atom`() async throws {
        let text = """
        ---
        title: "Architecture"
        created: 2026-04-03
        tags: ["Swift", "Search"]
        ---

        Protocol boundaries
        """
        let target = try readableTarget(path: "notes/design.md", format: .markdown)
        let atoms = try await TextSearchAtomProvider().atoms(
            for: target,
            snapshot: FileSnapshot(data: Data(text.utf8), modifiedDate: nil)
        )
        let atom = try #require(atoms.only)
        #expect(atom.locator == VaultSearchResult(
            path: "notes/design.md",
            format: .markdown
        ))
        #expect(atom.text.contains("Architecture"))
        #expect(atom.text.contains("Protocol boundaries"))
        #expect(!atom.text.contains("tags:"))
        #expect(atom.metadata?.tags == ["swift", "search"])
        #expect(atom.metadata?.created == "2026-04-03")
    }

    private func readableTarget(
        path: String,
        format: FileFormat
    ) throws -> ReadableFileTarget {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes", isDirectory: true),
            withIntermediateDirectories: true
        )
        let file = root.appendingPathComponent(path)
        try Data().write(to: file)
        return try ReadableFileTarget.resolve(
            path: path,
            format: format,
            vaultPath: root.path
        )
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
