import Foundation
import Testing
@testable import second_brain_mcp

@Suite("Generic files — formats and targets")
struct FileFormatTests {
    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "FileFormatTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/references", withIntermediateDirectories: true)
        return root
    }

    @Test("Concrete formats expose extension aliases")
    func aliases() {
        #expect(FileFormat.jpeg.extensions == ["jpg", "jpeg"])
        #expect(FileFormat.patch.extensions == ["patch", "diff"])
        #expect(FileFormat.json.extensions == ["json"])
        #expect(FileFormat.csv.extensions == ["csv"])
        #expect(FileFormat.heic.extensions == ["heic", "heif"])
        #expect(FileFormat.markdown.accepts(path: "notes/a.md"))
        #expect(!FileFormat.har.accepts(path: "notes/a.json"))
        #expect(FileFormat.json.accepts(path: "notes/a.json"))
        #expect(FileFormat.csv.accepts(path: "notes/a.csv"))
    }

    @Test("Image format normalization derives every alias from extensions")
    func imageNormalization() {
        for format in FileFormat.allCases where format.isImage {
            for fileExtension in format.extensions {
                #expect(FileFormat.imageFormat(
                    matching: "  \(fileExtension.uppercased())\n"
                ) == format)
            }
        }

        #expect(FileFormat.imageFormat(matching: "pdf") == nil)
        #expect(FileFormat.imageFormat(matching: "unknown") == nil)
    }

    @Test("Declared format and extension must agree")
    func mismatch() throws {
        let root = try makeVault()
        #expect(throws: FileRoutingError.self) {
            try ReadableFileTarget.resolve(path: "notes/capture.log", format: .har, vaultPath: root)
        }
    }

    @Test("Writable targets expose notes as their only structural area")
    func writableArea() throws {
        let root = try makeVault()
        let target = try WritableFileTarget.resolve(
            path: "notes/page.md",
            format: .markdown,
            vaultPath: root
        )
        #expect(target.area == .notes)
        #expect(target.readable.area == target.area)

        do {
            _ = try WritableFileTarget.resolve(
                path: "references/book.pdf",
                format: .pdf,
                vaultPath: root
            )
            Issue.record("Expected references target rejection")
        } catch FileRoutingError.areaNotWritable(let path) {
            #expect(path == "references/book.pdf")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Writable targets reject symlinks into references")
    func writableSymlinkCannotCrossAreaBoundary() throws {
        let root = try makeVault()
        try Data("reference".utf8).write(
            to: URL(fileURLWithPath: root + "/references/book.pdf")
        )
        try FileManager.default.createSymbolicLink(
            atPath: root + "/notes/reference-link",
            withDestinationPath: root + "/references"
        )

        #expect(throws: PathValidationError.self) {
            try WritableFileTarget.resolve(
                path: "notes/reference-link/book.pdf",
                format: .pdf,
                vaultPath: root
            )
        }

        // Read targets retain the intentional ability to follow a contained link.
        let readable = try ReadableFileTarget.resolve(
            path: "notes/reference-link/book.pdf",
            format: .pdf,
            vaultPath: root
        )
        #expect(readable.url.path == root + "/references/book.pdf")
    }

    @Test("Writable targets reject symlinks within notes")
    func writableSymlinkKeepsStorageAndGitPathsAligned() throws {
        let root = try makeVault()
        try FileManager.default.createDirectory(
            atPath: root + "/notes/real",
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: root + "/notes/link",
            withDestinationPath: root + "/notes/real"
        )

        #expect(throws: PathValidationError.self) {
            try WritableFileTarget.resolve(
                path: "notes/link/page.md",
                format: .markdown,
                vaultPath: root
            )
        }
    }
}
