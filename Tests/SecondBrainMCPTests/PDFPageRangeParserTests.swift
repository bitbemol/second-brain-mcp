import Testing
@testable import SecondBrainMCP

@Suite("PDF page range parser")
struct PDFPageRangeParserTests {
    @Test("Limits an inclusive range to the requested result count")
    func limitsInclusiveRange() {
        let pages = PDFPageRangeParser.pages(
            in: "3-12",
            totalPages: 20,
            maximumPages: 5
        )

        #expect(pages == [3, 4, 5, 6, 7])
    }

    @Test("Clamps a range to physical document boundaries")
    func clampsToDocumentBoundaries() {
        let pages = PDFPageRangeParser.pages(
            in: "0-50",
            totalPages: 3,
            maximumPages: 20
        )

        #expect(pages == [1, 2, 3])
    }

    @Test("Falls back to the first pages for a malformed range")
    func malformedRangeUsesDefaultSelection() {
        let pages = PDFPageRangeParser.pages(
            in: "chapter-one",
            totalPages: 10,
            maximumPages: 3
        )

        #expect(pages == [1, 2, 3])

        #expect(
            PDFPageRangeParser.pages(
                in: "1-garbage-3",
                totalPages: 10,
                maximumPages: 3
            ) == [1, 2, 3]
        )
    }

    @Test("Returns no pages for an unavailable selection")
    func unavailableSelectionIsEmpty() {
        #expect(
            PDFPageRangeParser.pages(
                in: "8-4",
                totalPages: 10,
                maximumPages: 5
            ).isEmpty
        )
        #expect(
            PDFPageRangeParser.pages(
                in: "11-20",
                totalPages: 10,
                maximumPages: 5
            ).isEmpty
        )
    }

    @Test("Non-positive limits cannot create an invalid Swift range")
    func nonPositiveLimitIsEmpty() {
        #expect(
            PDFPageRangeParser.pages(
                in: "not-a-range",
                totalPages: 10,
                maximumPages: 0
            ).isEmpty
        )
        #expect(
            PDFPageRangeParser.pages(
                in: "1-5",
                totalPages: 10,
                maximumPages: -1
            ).isEmpty
        )
    }

    @Test("Extreme page values cannot overflow selection arithmetic")
    func extremePageValuesAreSafe() {
        let maximumValue = String(Int.max)

        #expect(
            PDFPageRangeParser.pages(
                in: "\(maximumValue)-\(maximumValue)",
                totalPages: 10,
                maximumPages: Int.max
            ).isEmpty
        )
    }
}
