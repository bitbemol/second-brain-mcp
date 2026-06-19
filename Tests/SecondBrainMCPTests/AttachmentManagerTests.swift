import Testing
import Foundation
@testable import SecondBrainMCP

@Suite("AttachmentManager")
struct AttachmentManagerTests {

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "AttachmentManagerTests-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/notes/img", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/notes/img/a.png", contents: Data(count: 100))
        fm.createFile(atPath: root + "/notes/b.jpg", contents: Data(count: 50))
        fm.createFile(atPath: root + "/notes/c.webp", contents: Data(count: 10))
        fm.createFile(atPath: root + "/notes/sub-d.png", contents: Data(count: 20))
        fm.createFile(atPath: root + "/notes/data.csv", contents: Data(count: 30))
        fm.createFile(atPath: root + "/notes/note.md", contents: Data("x".utf8))
        fm.createFile(atPath: root + "/notes/board.canvas", contents: Data("{}".utf8))
        fm.createFile(atPath: root + "/notes/.gitkeep.md", contents: Data())
        fm.createFile(atPath: root + "/notes/.DS_Store", contents: Data())
        return root
    }

    // MARK: - Listing

    @Test("Lists attachments, excludes notes/canvas/placeholders")
    func listing() async throws {
        let root = try makeVault()
        let mgr = AttachmentManager(vaultPath: root)
        let items = try await mgr.list()
        let paths = Set(items.map(\.relativePath))
        #expect(paths == [
            "notes/img/a.png", "notes/b.jpg", "notes/c.webp", "notes/sub-d.png", "notes/data.csv"
        ])
        #expect(!paths.contains { $0.hasSuffix(".md") })
        #expect(!paths.contains { $0.hasSuffix(".canvas") })
        #expect(!paths.contains { $0.contains(".gitkeep") || $0.contains(".DS_Store") })
    }

    @Test("Readable flag is true for read_image formats, false for other files")
    func readableFlag() async throws {
        let root = try makeVault()
        let mgr = AttachmentManager(vaultPath: root)
        let items = try await mgr.list()
        let png = try #require(items.first { $0.relativePath == "notes/img/a.png" })
        let jpg = try #require(items.first { $0.relativePath == "notes/b.jpg" })
        let csv = try #require(items.first { $0.relativePath == "notes/data.csv" })
        #expect(png.readable == true)
        #expect(jpg.readable == true)    // jpg is now a supported read_image format
        #expect(jpg.ext == "jpg")
        #expect(csv.readable == false)   // non-image file
        #expect(csv.ext == "csv")
    }

    @Test("Reports byte size")
    func size() async throws {
        let root = try makeVault()
        let mgr = AttachmentManager(vaultPath: root)
        let items = try await mgr.list()
        let png = try #require(items.first { $0.relativePath == "notes/img/a.png" })
        #expect(png.sizeBytes == 100)
    }

    @Test("Scopes to a subdirectory")
    func scoped() async throws {
        let root = try makeVault()
        let mgr = AttachmentManager(vaultPath: root)
        let items = try await mgr.list(directory: "notes/img")
        #expect(items.map(\.relativePath) == ["notes/img/a.png"])
    }

    @Test("Directory outside notes/ is rejected")
    func outsideNotes() async throws {
        let root = try makeVault()
        let mgr = AttachmentManager(vaultPath: root)
        await #expect(throws: AttachmentManager.AttachmentError.self) {
            try await mgr.list(directory: "references")
        }
    }

    // MARK: - Soft-delete

    @Test("Soft-deletes an attachment to .trash/ and drops it from the listing")
    func deleteSoftDeletes() async throws {
        let root = try makeVault()
        let mgr = AttachmentManager(vaultPath: root)

        let msg = try await mgr.delete(relativePath: "notes/b.jpg")
        #expect(msg.contains(".trash/"))
        #expect(!FileManager.default.fileExists(atPath: root + "/notes/b.jpg"))   // gone from notes/

        let trashed = (try? FileManager.default.contentsOfDirectory(atPath: root + "/.trash")) ?? []
        #expect(trashed.contains { $0.hasSuffix("_b.jpg") })                      // recoverable in .trash/

        let paths = Set(try await mgr.list().map(\.relativePath))
        #expect(!paths.contains("notes/b.jpg"))
    }

    @Test("Refuses to delete notes or canvases (those have their own tools)")
    func deleteRejectsContentTypes() async throws {
        let root = try makeVault()
        let mgr = AttachmentManager(vaultPath: root)
        await #expect(throws: AttachmentManager.AttachmentError.self) {
            try await mgr.delete(relativePath: "notes/note.md")
        }
        await #expect(throws: AttachmentManager.AttachmentError.self) {
            try await mgr.delete(relativePath: "notes/board.canvas")
        }
        #expect(FileManager.default.fileExists(atPath: root + "/notes/note.md"))
        #expect(FileManager.default.fileExists(atPath: root + "/notes/board.canvas"))
    }

    @Test("Rejects a missing attachment and any path outside notes/")
    func deleteRejectsMissingAndOutside() async throws {
        let root = try makeVault()
        let mgr = AttachmentManager(vaultPath: root)
        await #expect(throws: AttachmentManager.AttachmentError.self) {
            try await mgr.delete(relativePath: "notes/nope.png")
        }
        await #expect(throws: AttachmentManager.AttachmentError.self) {
            try await mgr.delete(relativePath: "references/x.png")
        }
    }
}
