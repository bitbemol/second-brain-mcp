import PDFKit
import Testing
@testable import SecondBrainMCP

@Suite("PDF text extraction")
struct PDFTextExtractorTests {
    @Test("Search stops as soon as the requested pages are found")
    func searchStopsAtResultLimit() {
        // This lightweight PDFKit double generates page text in memory. No PDF
        // fixture or copyrighted document is stored in the repository.
        let document = SearchPDFDocument(pageTexts: [
            "Needle on the first page",
            "No match here",
            "another NEEDLE",
            "needle that must never be loaded",
        ])

        let results = PDFTextExtractor.searchDocument(
            document,
            query: "needle",
            maxResults: 2
        )

        #expect(results == [1, 3])
        #expect(document.accessedPageIndexes == [0, 1, 2])
    }

    @Test("Empty queries and non-positive limits perform no page work")
    func emptySearchesDoNoWork() {
        let document = SearchPDFDocument(pageTexts: ["text"])

        #expect(PDFTextExtractor.searchDocument(document, query: "").isEmpty)
        #expect(
            PDFTextExtractor.searchDocument(
                document,
                query: "text",
                maxResults: 0
            ).isEmpty
        )
        #expect(document.accessedPageIndexes.isEmpty)
    }
}

private final class SearchPDFDocument: PDFDocument {
    private let pageTexts: [String]
    private(set) var accessedPageIndexes: [Int] = []

    init(pageTexts: [String]) {
        self.pageTexts = pageTexts
        super.init()
    }

    override var pageCount: Int { pageTexts.count }

    override func page(at index: Int) -> PDFPage? {
        accessedPageIndexes.append(index)
        return SearchPDFPage(text: pageTexts[index])
    }
}

private final class SearchPDFPage: PDFPage {
    private let pageText: String

    init(text: String) {
        self.pageText = text
        super.init()
    }

    override var string: String? { pageText }
}
