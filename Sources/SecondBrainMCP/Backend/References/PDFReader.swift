import Foundation
import PDFKit

/// Read-only PDF behavior used by the generic file router.
struct PDFReader: Sendable {
    /// Creates a stateless PDF reader for already validated targets.
    init() {}

    /// Opens a PDF and selects pages by search, book label, physical page, or range.
    ///
    /// Selection precedence is `query`, `bookPage`, `page`, then `pageRange`.
    /// With no selector, the first `maxPages` pages are returned.
    ///
    /// - Parameters:
    ///   - target: Path and extension-validated PDF target.
    ///   - page: Optional one-based physical PDF page number.
    ///   - pageRange: Optional inclusive physical range in `start-end` form.
    ///   - bookPage: Optional printed page label, such as `xii` or `42`.
    ///   - query: Optional case-insensitive full-document text query.
    ///   - maxPages: Maximum number of pages selected by a query, range, or default read.
    /// - Returns: Document metadata and rendered page content.
    /// - Throws: ``VaultFileInspector/InspectionError`` when the target is absent
    ///   or not a regular file, ``FileResourcePolicy/Violation`` when it is too
    ///   large, or ``PDFReadError`` when PDFKit cannot open it.
    func read(
        target: ReadableFileTarget,
        page: Int? = nil,
        pageRange: String? = nil,
        bookPage: String? = nil,
        query: String? = nil,
        maxPages: Int = 5
    ) throws -> PDFReadResult {
        let metadata = try VaultFileInspector.inspect(target)
        try FileResourcePolicy.validate(
            bytes: metadata.byteCount,
            format: target.format,
            path: target.relativePath
        )
        guard let document = PDFDocument(url: target.url) else {
            throw PDFReadError.cannotOpenPDF(target.relativePath)
        }

        let attributes = document.documentAttributes
        let pdfTitle = attributes?[PDFDocumentAttribute.titleAttribute] as? String
        let title = pdfTitle ?? MarkdownSupport.titleFromFilename(target.url.lastPathComponent)
        let renderedPages: [RenderedPDFPage]

        if let query {
            let pages = PDFTextExtractor.searchDocument(document, query: query, maxResults: maxPages)
            renderedPages = PDFPageRenderer.renderPages(
                in: document,
                pageNumbers: pages
            )
        } else if let bookPage {
            let resolvedPage = PDFDocumentNavigation.resolvePage(
                label: bookPage,
                in: document
            ) ?? Int(bookPage)
            renderedPages = resolvedPage.map {
                PDFPageRenderer.renderPages(in: document, pageNumbers: [$0])
            } ?? []
        } else if let page {
            renderedPages = PDFPageRenderer.renderPages(
                in: document,
                pageNumbers: [page]
            )
        } else if let pageRange {
            let pages = PDFPageRangeParser.pages(
                in: pageRange,
                totalPages: document.pageCount,
                maximumPages: maxPages
            )
            renderedPages = PDFPageRenderer.renderPages(
                in: document,
                pageNumbers: pages
            )
        } else {
            let count = min(document.pageCount, maxPages)
            let pages = count > 0 ? Array(1...count) : []
            renderedPages = PDFPageRenderer.renderPages(
                in: document,
                pageNumbers: pages
            )
        }

        return PDFReadResult(
            title: title,
            totalPages: document.pageCount,
            renderedPages: renderedPages,
            outline: PDFDocumentNavigation.outline(in: document)
        )
    }
}
