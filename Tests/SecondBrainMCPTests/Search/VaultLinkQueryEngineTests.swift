import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Vault link query engine` {
    @Test
    func `Resolve returns every ambiguous basename with the nearest candidate first`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Local", to: "notes/project/Target.md", under: root)
        try write("# Remote", to: "notes/archive/Target.md", under: root)
        try write("# Source", to: "notes/project/Source.md", under: root)

        let response = try await makeEngine(root: root).query(LinkQueryRequest(
            direction: .resolve,
            target: "[[Target|display name]]",
            fromPath: "notes/project/Source.md"
        ))

        #expect(response.direction == .resolve)
        #expect(response.nextCursor == nil)
        #expect(response.results.map(\.resolvedPath) == [
            "notes/project/Target.md",
            "notes/archive/Target.md",
        ])
        let allAmbiguous = response.results.allSatisfy(\.ambiguous)
        let allTargetsMatch = response.results.allSatisfy { $0.target == "Target" }
        let allAliasesMatch = response.results.allSatisfy { $0.alias == "display name" }
        let allKindsMatch = response.results.allSatisfy { $0.kind == .link }
        let allSourcesAreAbsent = response.results.allSatisfy { $0.sourcePath == nil }
        #expect(allAmbiguous)
        #expect(allTargetsMatch)
        #expect(allAliasesMatch)
        #expect(allKindsMatch)
        #expect(allSourcesAreAbsent)
    }

    private func makeEngine(root: URL) -> VaultLinkQueryEngine {
        let capabilities = FileCapabilities(formats: [
            .init(format: .markdown, operations: [.read: [.notes]]),
            .init(format: .png, operations: [.read: [.notes, .references]]),
            .init(format: .pdf, operations: [.read: [.references]]),
        ])
        return VaultLinkQueryEngine(
            vaultPath: root.path,
            capabilities: capabilities,
            store: VaultCRUDStore(vaultPath: root.path),
            access: VaultAccessCoordinator(
                lockURL: root.appendingPathComponent(".vault-access.lock")
            )
        )
    }

    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultLinkQueryEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("references", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func write(_ content: String, to path: String, under root: URL) throws {
        let destination = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: destination)
    }
}
