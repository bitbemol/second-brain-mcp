import Foundation
import PDFKit
import Testing
@testable import second_brain_mcp

@Suite
struct `PDF page rendering` {
    @Test
    func `Extreme direct page values are rejected before index conversion`() throws {
        // An empty in-memory PDF is sufficient: the historical bug trapped while
        // evaluating `Int.min - 1`, before PDFKit could inspect the document.
        let document = PDFDocument()

        let rendering = try PDFPageRenderer.renderPages(
            in: document,
            pageNumbers: [.min, 0, .max]
        )

        #expect(rendering.pages.isEmpty)
        #expect(rendering.retainedPayloadBytes == 0)
    }

    @Test
    func `Rendered PDF text and wire-equivalent payload stay bounded`() throws {
        let data = try generatedSearchPDF(pages: [
            "first page text",
            "second page text",
        ])
        let document = try #require(PDFDocument(data: data))

        let textLimited = try PDFPageRenderer.renderPages(
            in: document,
            pageNumbers: [1, 2],
            maximumTextBytes: 4,
            maximumPayloadBytes: 8 * 1_024 * 1_024
        )
        #expect(textLimited.pages.count == 2)
        #expect(textLimited.textOmissionCount == 2)
        #expect(textLimited.pages.allSatisfy { $0.extractedText == nil })
        #expect(textLimited.retainedPayloadBytes <= 8 * 1_024 * 1_024)

        let payloadLimited = try PDFPageRenderer.renderPages(
            in: document,
            pageNumbers: [1, 2],
            maximumTextBytes: 1_024,
            maximumPayloadBytes: 1
        )
        #expect(payloadLimited.pages.isEmpty)
        #expect(payloadLimited.payloadOmissionCount == 2)
        #expect(payloadLimited.retainedPayloadBytes == 0)

        let wireBudget = 1 * 1_024 * 1_024
        let wireBounded = try PDFPageRenderer.renderPages(
            in: document,
            pageNumbers: [1, 2],
            maximumTextBytes: 1_024,
            maximumPayloadBytes: wireBudget
        )
        var contents: [VaultFileContent] = []
        for page in wireBounded.pages {
            if let text = page.extractedText { contents.append(.text(text)) }
            contents.append(.image(data: page.jpegData, mimeType: "image/jpeg"))
        }
        let mapped = FileToolResultMapper.success(FileOperationOutput(
            contents: contents
        ))
        #expect(try JSONEncoder().encode(mapped).count
            <= wireBudget + FileReadRequestLimits.PDFRenderedPayloadEnvelopeBytes)
    }

    @Test
    func `PDF metadata is sanitized while it is bounded`() {
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
