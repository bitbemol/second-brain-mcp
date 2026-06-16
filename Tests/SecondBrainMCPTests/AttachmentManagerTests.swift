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
        fm.createFile(atPath: root + "/notes/note.md", contents: Data("x".utf8))
        fm.createFile(atPath: root + "/notes/board.canvas", contents: Data("{}".utf8))
        fm.createFile(atPath: root + "/notes/.gitkeep.md", contents: Data())
        fm.createFile(atPath: root + "/notes/.DS_Store", contents: Data())
        return root
    }

    @Test("Lists attachments, excludes notes/canvas/placeholders")
    func listing() throws {
        let root = try makeVault()
        let mgr = AttachmentManager(vaultPath: root)
        let items = try mgr.list()
        let paths = Set(items.map(\.relativePath))
        #expect(paths == [
            "notes/img/a.png", "notes/b.jpg", "notes/c.webp", "notes/sub-d.png"
        ])
        #expect(!paths.contains { $0.hasSuffix(".md") })
        #expect(!paths.contains { $0.hasSuffix(".canvas") })
        #expect(!paths.contains { $0.contains(".gitkeep") || $0.contains(".DS_Store") })
    }

    @Test("Readable flag is true only for read_image formats (PNG today)")
    func readableFlag() throws {
        let root = try makeVault()
        let mgr = AttachmentManager(vaultPath: root)
        let items = try mgr.list()
        let png = try #require(items.first { $0.relativePath == "notes/img/a.png" })
        let jpg = try #require(items.first { $0.relativePath == "notes/b.jpg" })
        #expect(png.readable == true)
        #expect(png.ext == "png")
        #expect(jpg.readable == false)
        #expect(jpg.ext == "jpg")
    }

    @Test("Reports byte size")
    func size() throws {
        let root = try makeVault()
        let mgr = AttachmentManager(vaultPath: root)
        let items = try mgr.list()
        let png = try #require(items.first { $0.relativePath == "notes/img/a.png" })
        #expect(png.sizeBytes == 100)
    }

    @Test("Scopes to a subdirectory")
    func scoped() throws {
        let root = try makeVault()
        let mgr = AttachmentManager(vaultPath: root)
        let items = try mgr.list(directory: "notes/img")
        #expect(items.map(\.relativePath) == ["notes/img/a.png"])
    }

    @Test("Directory outside notes/ is rejected")
    func outsideNotes() throws {
        let root = try makeVault()
        let mgr = AttachmentManager(vaultPath: root)
        #expect(throws: AttachmentManager.AttachmentError.self) {
            try mgr.list(directory: "references")
        }
    }
}
