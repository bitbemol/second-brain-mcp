import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `PDFReader — physical page boundary` {
    @Test
    func `Reports an unreadable validated PDF target`() async throws {
        let root = NSTemporaryDirectory() + "PDFReaderTests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        let target = try ReadableFileTarget.resolve(
            path: "references/missing.pdf",
            format: .pdf,
            vaultPath: root
        )

        await #expect(throws: VaultFileInspector.InspectionError.self) {
            try await PDFReader().read(target: target)
        }
    }

    @Test
    func `Rejects oversized PDFs before opening`() async throws {
        let root = NSTemporaryDirectory() + "PDFReaderSizeTests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        let target = try ReadableFileTarget.resolve(
            path: "references/oversized.pdf",
            format: .pdf,
            vaultPath: root
        )
        try Data().write(to: target.url)
        let handle = try FileHandle(forWritingTo: target.url)
        try handle.truncate(atOffset: UInt64(FileFormat.pdf.maximumFileBytes + 1))
        try handle.close()

        await #expect(throws: FileResourcePolicy.Violation.self) {
            try await PDFReader().read(target: target)
        }
    }

    @Test
    func `Defaults to the first physical page`() async throws {
        let fixture = try makePDF(pages: ["first", "second"])
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let pages = try await PDFReader().read(target: fixture.target)

        #expect(pages.map(\.pageNumber) == [1])
        #expect(pages.first?.text.contains("first") == true)
    }

    @Test
    func `Reads discrete physical pages in requested order`() async throws {
        let fixture = try makePDF(pages: ["first", "second", "third"])
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let pages = try await PDFReader().read(
            target: fixture.target,
            options: ReadFileOptions(pages: [3, 1])
        )

        #expect(pages.map(\.pageNumber) == [3, 1])
        #expect(pages[0].text.contains("third"))
        #expect(pages[1].text.contains("first"))
    }

    @Test
    func `Reads an inclusive physical page range`() async throws {
        let fixture = try makePDF(pages: ["one", "two", "three", "four"])
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let pages = try await PDFReader().read(
            target: fixture.target,
            options: ReadFileOptions(pageRange: "2-4")
        )

        #expect(pages.map(\.pageNumber) == [2, 3, 4])
    }

    @Test
    func `Rejects invalid selectors before opening PDFKit`() async throws {
        let root = NSTemporaryDirectory() + "PDFReaderSelectorTests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        let target = try ReadableFileTarget.resolve(
            path: "references/missing.pdf",
            format: .pdf,
            vaultPath: root
        )
        let invalid = [
            ReadFileOptions(page: 1, pages: [2]),
            ReadFileOptions(pages: []),
            ReadFileOptions(pages: [1, 1]),
            ReadFileOptions(pages: Array(1...21)),
            ReadFileOptions(page: 0),
            ReadFileOptions(pageRange: "5-2"),
            ReadFileOptions(pageRange: "1-21"),
            ReadFileOptions(pageRange: String(
                repeating: "1",
                count: FileReadRequestLimits.maximumPDFPageRangeBytes + 1
            )),
        ]

        for options in invalid {
            await #expect(throws: PDFReadError.self) {
                try await PDFReader().read(target: target, options: options)
            }
        }
    }

    @Test
    func `Rejects a physical page beyond the document`() async throws {
        let fixture = try makePDF(pages: ["only"])
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        await #expect(throws: PDFReadError.self) {
            try await PDFReader().read(
                target: fixture.target,
                options: ReadFileOptions(page: 2)
            )
        }
    }

    @Test
    func `PDF file operation returns only page text and a PNG image`() async throws {
        let fixture = try makePDF(pages: ["atomic page text"])
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let output = try await PDFFileOperations(reader: PDFReader()).read(
            ReadFileRequest(
                format: .pdf,
                path: fixture.path,
                options: .default
            ),
            target: fixture.target
        )

        #expect(output.contents.count == 2)
        guard case .text(let text) = output.contents.first else {
            Issue.record("Expected one page text block")
            return
        }
        #expect(text.contains("PDF Page 1"))
        #expect(text.contains("atomic page text"))
        guard case .image(let imageData, let mimeType) = output.contents.last else {
            Issue.record("Expected one page image block")
            return
        }
        #expect(mimeType == "image/png")
        #expect(imageData.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    private func makePDF(
        pages: [String]
    ) throws -> (root: String, path: String, target: ReadableFileTarget) {
        let root = NSTemporaryDirectory() + "PDFPhysicalPageTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        let path = "references/fixture.pdf"
        try generatedSearchPDF(pages: pages).write(
            to: URL(fileURLWithPath: root).appendingPathComponent(path)
        )
        return (
            root,
            path,
            try ReadableFileTarget.resolve(
                path: path,
                format: .pdf,
                vaultPath: root
            )
        )
    }
}
