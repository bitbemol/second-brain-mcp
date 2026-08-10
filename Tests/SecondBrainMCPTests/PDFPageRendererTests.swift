import Foundation
import PDFKit
import Testing
@testable import second_brain_mcp

@Suite
struct `PDF page rendering` {
    @Test
    func `Renders display-safe text and PNG page images`() throws {
        let data = try generatedSearchPDF(pages: ["first page text"])
        let document = try #require(PDFDocument(data: data))

        let pages = try PDFPageRenderer.renderPages(
            in: document,
            pageNumbers: [1]
        )

        let page = try #require(pages.first)
        #expect(page.pageNumber == 1)
        #expect(page.text.contains("first page text"))
        #expect(page.pngData.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test
    func `Invalid physical pages fail instead of disappearing`() throws {
        let document = PDFDocument()

        #expect(throws: PDFReadError.self) {
            try PDFPageRenderer.renderPages(
                in: document,
                pageNumbers: [.min, 0, .max]
            )
        }
    }

    @Test
    func `A response budget failure rejects the complete page set`() throws {
        let data = try generatedSearchPDF(pages: ["first", "second"])
        let document = try #require(PDFDocument(data: data))

        #expect(throws: PDFReadError.self) {
            try PDFPageRenderer.renderPages(
                in: document,
                pageNumbers: [1, 2],
                maximumTextBytes: 1_024,
                maximumPayloadBytes: 1
            )
        }
    }

    @Test
    func `PDF text is sanitized while it is bounded`() {
        let bounded = PDFDisplayText.bounded(
            "A\u{0000}" + String(repeating: "x", count: 100_000),
            maximumCharacters: 8,
            maximumBytes: 8
        )
        #expect(bounded.value == "A xxxxxx")
        #expect(bounded.truncated)
        #expect(bounded.value.utf8.count == 8)
    }
}
