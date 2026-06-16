import Testing
import Foundation
@testable import SecondBrainMCP

@Suite("VaultEnumerator")
struct VaultEnumeratorTests {

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "VaultEnumeratorTests-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/notes/sub", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/notes/.hidden", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/notes/a.md", contents: Data("a".utf8))
        fm.createFile(atPath: root + "/notes/b.canvas", contents: Data("b".utf8))
        fm.createFile(atPath: root + "/notes/.gitkeep.md", contents: Data())
        fm.createFile(atPath: root + "/notes/.DS_Store", contents: Data())
        fm.createFile(atPath: root + "/notes/sub/c.md", contents: Data("c".utf8))
        fm.createFile(atPath: root + "/notes/sub/.gitkeep.md", contents: Data())
        fm.createFile(atPath: root + "/notes/.hidden/secret.md", contents: Data("x".utf8))
        return root
    }

    @Test("Filters by extension; skips dotfiles, .gitkeep placeholders, hidden dirs")
    func basicFilter() throws {
        let root = try makeVault()
        let entries = try VaultEnumerator.files(
            vaultPath: root, directory: nil, defaultDir: "notes", recursive: true,
            include: { $0 == "md" }
        )
        let paths = Set(entries.map(\.relativePath))
        #expect(paths == ["notes/a.md", "notes/sub/c.md"])
        #expect(!paths.contains { $0.contains(".gitkeep") })
        #expect(!paths.contains { $0.contains(".hidden") })
    }

    @Test("Canvas extension filter")
    func canvasFilter() throws {
        let root = try makeVault()
        let entries = try VaultEnumerator.files(
            vaultPath: root, directory: nil, defaultDir: "notes", recursive: true,
            include: { $0 == "canvas" }
        )
        #expect(entries.map(\.relativePath) == ["notes/b.canvas"])
    }

    @Test("Trailing-slash directory does not double the slash")
    func noDoubleSlash() throws {
        let root = try makeVault()
        let entries = try VaultEnumerator.files(
            vaultPath: root, directory: "notes/", defaultDir: "notes", recursive: true,
            include: { $0 == "md" }
        )
        #expect(entries.allSatisfy { !$0.relativePath.contains("//") })
        #expect(entries.contains { $0.relativePath == "notes/a.md" })
    }

    @Test("Non-recursive lists only the top level")
    func nonRecursive() throws {
        let root = try makeVault()
        let entries = try VaultEnumerator.files(
            vaultPath: root, directory: nil, defaultDir: "notes", recursive: false,
            include: { $0 == "md" }
        )
        #expect(entries.map(\.relativePath) == ["notes/a.md"])
    }

    @Test("Subdirectory scope")
    func subdirectory() throws {
        let root = try makeVault()
        let entries = try VaultEnumerator.files(
            vaultPath: root, directory: "notes/sub", defaultDir: "notes", recursive: true,
            include: { $0 == "md" }
        )
        #expect(entries.map(\.relativePath) == ["notes/sub/c.md"])
    }

    @Test("Missing directory returns empty")
    func missingDir() throws {
        let root = try makeVault()
        let entries = try VaultEnumerator.files(
            vaultPath: root, directory: "notes/nope", defaultDir: "notes", recursive: true,
            include: { _ in true }
        )
        #expect(entries.isEmpty)
    }

    @Test("Directory outside the root throws")
    func outsideRoot() throws {
        let root = try makeVault()
        #expect(throws: VaultEnumerator.EnumeratorError.self) {
            try VaultEnumerator.files(
                vaultPath: root, directory: "references", defaultDir: "notes", recursive: true,
                include: { _ in true }
            )
        }
    }

    @Test("list_notes no longer emits a double slash, and drops .gitkeep")
    func listNotesRegression() async throws {
        let root = try makeVault()
        let config = try ServerConfig.parse(arguments: ["binary", "--vault", root])
        let vault = VaultManager(config: config)
        let notes = try await vault.listNotes(directory: "notes/")
        #expect(notes.allSatisfy { !$0.relativePath.contains("//") })
        #expect(notes.contains { $0.relativePath == "notes/a.md" })
        #expect(!notes.contains { $0.relativePath.contains(".gitkeep") })
    }
}
