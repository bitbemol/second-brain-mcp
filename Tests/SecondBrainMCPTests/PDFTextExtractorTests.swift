import PDFKit
import Testing
@testable import second_brain_mcp

@Suite
struct `PDF text extraction` {
    @Test
    func `Ranked PDF search returns body evidence before navigation pages`() throws {
        let document = SearchPDFDocument(pageTexts: [
            "Table of Contents\nbinary search ........ 3",
            "Preface",
            "Binary search compares the midpoint and narrows the range.",
            "Index\nbinary search, 3",
        ])

        let result = try PDFTextExtractor.rankedSearchDocument(
            document,
            query: "binary search",
            maxResults: 2
        )

        #expect(result.pages == [3, 4])
        #expect(result.matchingPageCountLowerBound == 3)
        #expect(result.moreMatchesAvailable)
        #expect(result.textExtractionStatus == .extracted)
        #expect(result.scannedPageCount == 4)
        #expect(!result.ocrPerformed)
    }

    @Test
    func `Ranked PDF search discloses scan and text limitations`() throws {
        let partial = SearchPDFDocument(pageTexts: ["first", "target", "later target"])
        let partialResult = try PDFTextExtractor.rankedSearchDocument(
            partial,
            query: "target",
            maximumScannedPages: 2
        )
        #expect(partialResult.pages == [2])
        #expect(partialResult.matchingPageCountLowerBound == 1)
        #expect(partialResult.moreMatchesAvailable)
        #expect(partialResult.textExtractionStatus == .partial)

        let imageOnly = SearchPDFDocument(pageTexts: ["", " \n\t "])
        let noText = try PDFTextExtractor.rankedSearchDocument(
            imageOnly,
            query: "anything"
        )
        #expect(noText.pages.isEmpty)
        #expect(noText.textExtractionStatus == .noExtractableText)
        #expect(!noText.ocrPerformed)

        let locked = SearchPDFDocument(pageTexts: ["hidden text"], locked: true)
        let lockedResult = try PDFTextExtractor.rankedSearchDocument(
            locked,
            query: "hidden"
        )
        #expect(lockedResult.pages.isEmpty)
        #expect(lockedResult.scannedPageCount == 0)
        #expect(lockedResult.textExtractionStatus == .locked)

        let inaccessible = SearchPDFDocument(
            pageTexts: ["visible target", "unavailable"],
            missingPageIndexes: [1]
        )
        let inaccessibleResult = try PDFTextExtractor.rankedSearchDocument(
            inaccessible,
            query: "target"
        )
        #expect(inaccessibleResult.pages == [1])
        #expect(inaccessibleResult.scannedPageCount == 1)
        #expect(inaccessibleResult.textExtractionStatus == .partial)
        #expect(inaccessibleResult.moreMatchesAvailable)

        let textLimited = SearchPDFDocument(pageTexts: [
            "first",
            "target " + String(repeating: "large ", count: 20),
        ])
        let textLimitedResult = try PDFTextExtractor.rankedSearchDocument(
            textLimited,
            query: "target",
            maximumTextBytes: 10
        )
        #expect(textLimitedResult.pages.isEmpty)
        #expect(textLimitedResult.scannedPageCount == 1)
        #expect(textLimitedResult.textExtractionStatus == .partial)
        #expect(textLimitedResult.moreMatchesAvailable)

        let whitespaceHeavy = SearchPDFDocument(pageTexts: [
            String(repeating: " ", count: 32) + "target",
        ])
        let whitespaceLimited = try PDFTextExtractor.rankedSearchDocument(
            whitespaceHeavy,
            query: "target",
            maximumTextBytes: 16
        )
        #expect(whitespaceLimited.pages.isEmpty)
        #expect(whitespaceLimited.scannedPageCount == 0)
        #expect(whitespaceLimited.textExtractionStatus == .partial)
        #expect(whitespaceLimited.moreMatchesAvailable)

        let occurrenceLimited = SearchPDFDocument(pageTexts: [
            "target target target target",
            "target on a later page",
        ])
        let occurrenceLimitedResult = try PDFTextExtractor.rankedSearchDocument(
            occurrenceLimited,
            query: "target",
            maximumOccurrencesPerPage: 100,
            maximumOccurrencesPerRequest: 3
        )
        #expect(occurrenceLimitedResult.pages == [1])
        #expect(occurrenceLimitedResult.scannedPageCount == 1)
        #expect(occurrenceLimitedResult.textExtractionStatus == .partial)
        #expect(occurrenceLimitedResult.moreMatchesAvailable)

        let rendered = partialResult.recordingRendering(PDFPageRenderResult(
            pages: [],
            renderFailureCount: partialResult.pages.count,
            payloadOmissionCount: 0,
            textOmissionCount: 0,
            retainedPayloadBytes: 0
        ))
        #expect(rendered.renderedPageCount == 0)
        #expect(rendered.renderFailureCount == partialResult.pages.count)
        #expect(rendered.moreMatchesAvailable)

        let payloadOmitted = partialResult.recordingRendering(
            PDFPageRenderResult(
                pages: [],
                renderFailureCount: 0,
                payloadOmissionCount: partialResult.pages.count,
                textOmissionCount: 0,
                retainedPayloadBytes: 0
            )
        )
        #expect(payloadOmitted.renderFailureCount == 0)
        #expect(payloadOmitted.moreMatchesAvailable)
    }
}

private final class SearchPDFDocument: PDFDocument {
    private let pageTexts: [String]
    private let locked: Bool
    private let missingPageIndexes: Set<Int>
    private(set) var accessedPageIndexes: [Int] = []

    init(
        pageTexts: [String],
        locked: Bool = false,
        missingPageIndexes: Set<Int> = []
    ) {
        self.pageTexts = pageTexts
        self.locked = locked
        self.missingPageIndexes = missingPageIndexes
        super.init()
    }

    override var pageCount: Int { pageTexts.count }
    override var isLocked: Bool { locked }

    override func page(at index: Int) -> PDFPage? {
        accessedPageIndexes.append(index)
        if missingPageIndexes.contains(index) { return nil }
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
