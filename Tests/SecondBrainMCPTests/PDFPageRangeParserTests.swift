import Testing
@testable import second_brain_mcp

@Suite
struct `PDF page range parser` {
    @Test
    func `Limits an inclusive range to the requested result count`() {
        let pages = PDFPageRangeParser.pages(
            in: "3-12",
            totalPages: 20,
            maximumPages: 5
        )

        #expect(pages == [3, 4, 5, 6, 7])
    }

    @Test
    func `Clamps a range to physical document boundaries`() {
        let pages = PDFPageRangeParser.pages(
            in: "0-50",
            totalPages: 3,
            maximumPages: 20
        )

        #expect(pages == [1, 2, 3])
    }

    @Test
    func `Falls back to the first pages for a malformed range`() {
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

    @Test
    func `Returns no pages for an unavailable selection`() {
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

    @Test
    func `Non-positive limits cannot create an invalid Swift range`() {
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

    @Test
    func `Extreme page values cannot overflow selection arithmetic`() {
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
