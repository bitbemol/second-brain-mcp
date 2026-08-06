import PDFKit
import Testing
@testable import SecondBrainMCP

@Suite("PDF page rendering")
struct PDFPageRendererTests {
    @Test("Extreme direct page values are rejected before index conversion")
    func rejectsExtremePageValues() {
        // An empty in-memory PDF is sufficient: the historical bug trapped while
        // evaluating `Int.min - 1`, before PDFKit could inspect the document.
        let document = PDFDocument()

        let pages = PDFPageRenderer.renderPages(
            in: document,
            pageNumbers: [.min, 0, .max]
        )

        #expect(pages.isEmpty)
    }
}
