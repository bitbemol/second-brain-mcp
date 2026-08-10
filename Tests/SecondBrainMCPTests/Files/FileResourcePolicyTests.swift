import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `File resource policy` {
    @Test
    func `Every concrete format belongs to an explicit file-size tier`() {
        for format in [FileFormat.markdown, .canvas, .patch, .json, .csv] {
            #expect(format.maximumFileBytes == 10 * 1024 * 1024)
        }
        for format in [
            FileFormat.har, .log, .png, .jpeg, .gif, .webp, .heic, .tiff, .bmp,
        ] {
            #expect(format.maximumFileBytes == 25 * 1024 * 1024)
        }
        #expect(FileFormat.pdf.maximumFileBytes == 512 * 1024 * 1024)
    }

    @Test
    func `Production media defaults derive from stored-format limits`() {
        #expect(ImageLimits.default.maxFileBytes == FileFormat.png.maximumFileBytes)
        #expect(
            VideoImportConfiguration.default.maxOutputBytes
                == FileFormat.gif.maximumFileBytes
        )
    }

    @Test
    func `Text ingress enforces the selected format tier`() throws {
        let ingress = TextFileIngress()
        let limit = FileFormat.markdown.maximumFileBytes
        let root = NSTemporaryDirectory() + "TextFileIngressTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        let target = try WritableFileTarget.resolve(
            path: "notes/bounded.md",
            format: .markdown,
            vaultPath: root
        )
        let accepted = String(repeating: "a", count: limit)
        let acceptedRequest = CreateFileRequest(

            format: .markdown,
            path: target.relativePath,
            content: accepted,
            source: nil,
            tags: [],
            transform: nil
        )
        #expect(try ingress.prepare(acceptedRequest, for: target).data.count == limit)
        #expect(throws: FileResourcePolicy.Violation.self) {
            try ingress.prepare(
                CreateFileRequest(

                    format: .markdown,
                    path: target.relativePath,
                    content: accepted + "a",
                    source: nil,
                    tags: [],
                    transform: nil
                ),
                for: target
            )
        }
    }
}
