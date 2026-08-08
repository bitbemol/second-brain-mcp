/// Bounded facts from a ranked full-document PDF text query.
struct PDFTextSearchResult: Sendable {
    /// Selected one-based physical pages, ranked by substantive evidence.
    let pages: [Int]
    /// Matches observed in the scanned portion of the document.
    let matchingPageCountLowerBound: Int
    /// Number of physical pages whose text was inspected.
    let scannedPageCount: Int
    /// Total physical pages in the PDF.
    let totalPageCount: Int
    /// Whether known or possible matching pages were omitted.
    let moreMatchesAvailable: Bool
    /// Text availability for the inspected document.
    let textExtractionStatus: PDFTextExtractionStatus
    /// Broad PDF queries never perform OCR implicitly.
    let ocrPerformed: Bool
    /// Matching pages successfully rendered for the caller.
    let renderedPageCount: Int
    /// Selected matching pages that PDFKit could not render.
    let renderFailureCount: Int

    init(
        pages: [Int],
        matchingPageCountLowerBound: Int,
        scannedPageCount: Int,
        totalPageCount: Int,
        moreMatchesAvailable: Bool,
        textExtractionStatus: PDFTextExtractionStatus,
        ocrPerformed: Bool,
        renderedPageCount: Int = 0,
        renderFailureCount: Int = 0
    ) {
        self.pages = pages
        self.matchingPageCountLowerBound = matchingPageCountLowerBound
        self.scannedPageCount = scannedPageCount
        self.totalPageCount = totalPageCount
        self.moreMatchesAvailable = moreMatchesAvailable
        self.textExtractionStatus = textExtractionStatus
        self.ocrPerformed = ocrPerformed
        self.renderedPageCount = renderedPageCount
        self.renderFailureCount = renderFailureCount
    }

    /// Adds rendering facts after text selection completes.
    func recordingRendering(_ rendering: PDFPageRenderResult) -> PDFTextSearchResult {
        let bounded = min(max(rendering.pages.count, 0), pages.count)
        let renderingWasPartial = rendering.renderFailureCount > 0
            || rendering.payloadOmissionCount > 0
            || rendering.textOmissionCount > 0
        return PDFTextSearchResult(
            pages: pages,
            matchingPageCountLowerBound: matchingPageCountLowerBound,
            scannedPageCount: scannedPageCount,
            totalPageCount: totalPageCount,
            moreMatchesAvailable: moreMatchesAvailable || renderingWasPartial,
            textExtractionStatus: rendering.textOmissionCount > 0
                ? .partial : textExtractionStatus,
            ocrPerformed: ocrPerformed,
            renderedPageCount: bounded,
            renderFailureCount: rendering.renderFailureCount
        )
    }
}
