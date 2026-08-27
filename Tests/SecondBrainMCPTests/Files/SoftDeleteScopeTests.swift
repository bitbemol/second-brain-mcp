import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Recoverable deletion scope` {
    @Test(arguments: [false, true])
    func `Deleting one file preserves its parent and unrelated Finder metadata`(
        hasFinderMetadata: Bool
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoftDeleteScopeTests-\(UUID().uuidString)")
        let parent = root.appendingPathComponent("notes/project")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("recoverable note".utf8)
        try original.write(to: parent.appendingPathComponent("note.md"))
        let metadata = parent.appendingPathComponent(".DS_Store")
        if hasFinderMetadata { try Data("unrelated Finder state".utf8).write(to: metadata) }
        let target = try WritableFileTarget.resolve(
            path: "notes/project/note.md", format: .markdown, vaultPath: root.path
        )
        let store = VaultCRUDStore(vaultPath: root.path)
        let snapshot = try await store.snapshot(target.readable)
        let deleted = try await store.softDelete(target: target, expectedRevision: snapshot.revision)

        #expect(FileManager.default.fileExists(atPath: parent.path))
        if hasFinderMetadata {
            #expect(FileManager.default.fileExists(atPath: metadata.path))
        }
        let recovered = try Data(contentsOf: root.appendingPathComponent(deleted.trashPath))
        #expect(recovered == original)
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("note.md").path))
    }
}
