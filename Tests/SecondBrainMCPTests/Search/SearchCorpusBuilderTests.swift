import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Search corpus resilience` {
    @Test
    func `One malformed note does not make healthy notes undiscoverable`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchCorpusBuilderTests-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: notes,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("healthy searchable text".utf8).write(
            to: notes.appendingPathComponent("healthy.md")
        )
        try Data([0xFF]).write(
            to: notes.appendingPathComponent("malformed.md")
        )

        let capabilities = FileCapabilities(formats: [
            .init(
                format: .markdown,
                operations: [.read: [.notes]]
            ),
        ])
        let builder = SearchCorpusBuilder(
            vaultPath: root.path,
            capabilities: capabilities,
            store: VaultCRUDStore(vaultPath: root.path),
            access: VaultAccessCoordinator(
                lockURL: root.appendingPathComponent(".vault-access.lock")
            )
        )

        let atoms = try await builder.atoms(in: .notes)

        #expect(atoms.map(\.locator.path) == ["notes/healthy.md"])
        #expect(atoms.map(\.text) == ["healthy searchable text"])
    }
}
