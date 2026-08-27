/// Failures produced while reading physical PDF pages.
enum PDFReadError: Error, CustomStringConvertible, CallerSafeError, Sendable {
    /// PDFKit could not open a document at the validated path.
    case cannotOpenPDF(String)
    /// The caller supplied invalid or conflicting physical-page selectors.
    case invalidSelection(String)
    /// A requested physical page does not exist.
    case pageOutOfBounds(page: Int, totalPages: Int)
    /// PDFKit could not rasterize one requested page.
    case cannotRenderPage(Int)
    /// The complete requested page set would exceed the response ceiling.
    case responseTooLarge(maximumBytes: Int)
    /// The bounded queue already contains the maximum number of PDF reads.
    case busy

    /// Audited recovery guidance. Arbitrary paths and internal details are never exposed.
    var callerSafeDescription: String {
        switch self {
        case .cannotOpenPDF:
            "Cannot open PDF; check that the file is a valid, readable PDF"
        case .invalidSelection:
            "Invalid PDF page selection; use unique positive pages or one inclusive page_range, with at most \(FileReadRequestLimits.maximumPDFPagesPerRead) pages"
        case .pageOutOfBounds(let page, let totalPages):
            totalPages > 0
                ? "PDF page \(page) is outside the document's 1...\(totalPages) range; choose an existing physical page"
                : "PDF has no pages; check the document before selecting a page"
        case .cannotRenderPage(let page):
            "Cannot render PDF page \(page); choose another page or check the PDF"
        case .responseTooLarge(let maximumBytes):
            "Selected PDF pages exceed the \(maximumBytes)-byte response limit; request fewer pages or a different page"
        case .busy:
            "PDF reader is busy; retry after an active PDF operation finishes"
        }
    }

    /// Internal diagnostic detail, distinct from the audited caller projection.
    var description: String {
        switch self {
        case .cannotOpenPDF(let path):
            return "Cannot open PDF: \(path)"
        case .invalidSelection(let message):
            return "Invalid PDF page selection: \(message)"
        case .pageOutOfBounds(let page, let totalPages):
            return "PDF page \(page) is outside the document's 1...\(totalPages) range"
        case .cannotRenderPage(let page):
            return "Cannot render PDF page \(page)"
        case .responseTooLarge(let maximumBytes):
            return "Selected PDF pages exceed the \(maximumBytes)-byte response limit; request fewer pages"
        case .busy:
            return "PDF reader is busy; retry this request later"
        }
    }
}
