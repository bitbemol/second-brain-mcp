import Foundation
import PDFKit

/// Read-only PDF behavior used by the generic file router.
struct PDFReader: Sendable {
    private let admission: PDFReadAdmission

    /// Creates a PDF reader with bounded expensive-read admission.
    init(admission: PDFReadAdmission = PDFReadAdmission()) {
        self.admission = admission
    }

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
    ///   large, ``PDFReadError`` for invalid queries, busy admission, or PDFKit
    ///   failures, and `CancellationError` when cooperative work is canceled.
    func read(
        target: ReadableFileTarget,
        page: Int? = nil,
        pageRange: String? = nil,
        bookPage: String? = nil,
        query: String? = nil,
        maxPages: Int = 5
    ) async throws -> PDFReadResult {
        if let query {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  query.utf8.count <= FileReadRequestLimits.maximumPDFQueryBytes else {
                throw PDFReadError.invalidQuery(
                    maximumBytes: FileReadRequestLimits.maximumPDFQueryBytes
                )
            }
        }
        if let bookPage {
            guard !bookPage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  bookPage.utf8.count <= FileReadRequestLimits.maximumPDFBookPageBytes else {
                throw PDFReadError.invalidSelector(
                    name: "book_page",
                    maximumBytes: FileReadRequestLimits.maximumPDFBookPageBytes
                )
            }
        }
        if let pageRange {
            guard !pageRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  pageRange.utf8.count <= FileReadRequestLimits.maximumPDFPageRangeBytes else {
                throw PDFReadError.invalidSelector(
                    name: "page_range",
                    maximumBytes: FileReadRequestLimits.maximumPDFPageRangeBytes
                )
            }
        }
        return try await admission.withPermit {
            try readAdmitted(
                target: target,
                page: page,
                pageRange: pageRange,
                bookPage: bookPage,
                query: query,
                maxPages: maxPages
            )
        }
    }

    /// Performs one read after aggregate temp-file admission succeeds.
    private func readAdmitted(
        target: ReadableFileTarget,
        page: Int?,
        pageRange: String?,
        bookPage: String?,
        query: String?,
        maxPages: Int
    ) throws -> PDFReadResult {
        let snapshot = try VaultFileInspector.temporarySnapshot(
            target,
            maximumBytes: target.format.maximumFileBytes
        )
        defer { snapshot.remove() }
        try Task.checkCancellation()
        guard let document = PDFDocument(url: snapshot.url) else {
            throw PDFReadError.cannotOpenPDF(target.relativePath)
        }

        let attributes = document.documentAttributes
        let pdfTitle = attributes?[PDFDocumentAttribute.titleAttribute] as? String
        let title = Self.boundedMetadata(
            pdfTitle ?? MarkdownSupport.titleFromFilename(target.url.lastPathComponent),
            maximumBytes: 2_048
        )
        let rendering: PDFPageRenderResult
        var queryStatus: PDFTextSearchResult?

        if let query {
            let search = try PDFTextExtractor.rankedSearchDocument(
                document,
                query: query,
                maxResults: maxPages
            )
            rendering = try PDFPageRenderer.renderPages(
                in: document,
                pageNumbers: search.pages
            )
            queryStatus = search.recordingRendering(rendering)
        } else if let bookPage {
            let resolvedPage = try PDFDocumentNavigation.resolvePage(
                label: bookPage,
                in: document
            ) ?? Int(bookPage)
            rendering = try resolvedPage.map {
                try PDFPageRenderer.renderPages(in: document, pageNumbers: [$0])
            } ?? PDFPageRenderResult.empty
        } else if let page {
            rendering = try PDFPageRenderer.renderPages(
                in: document,
                pageNumbers: [page]
            )
        } else if let pageRange {
            let pages = PDFPageRangeParser.pages(
                in: pageRange,
                totalPages: document.pageCount,
                maximumPages: maxPages
            )
            rendering = try PDFPageRenderer.renderPages(
                in: document,
                pageNumbers: pages
            )
        } else {
            let count = min(document.pageCount, maxPages)
            let pages = count > 0 ? Array(1...count) : []
            rendering = try PDFPageRenderer.renderPages(
                in: document,
                pageNumbers: pages
            )
        }

        return PDFReadResult(
            title: title,
            totalPages: document.pageCount,
            renderedPages: rendering.pages,
            outline: try PDFDocumentNavigation.outline(in: document),
            queryStatus: queryStatus,
            renderFailureCount: rendering.renderFailureCount,
            renderLimitOmissionCount: rendering.payloadOmissionCount,
            renderedTextOmissionCount: rendering.textOmissionCount
        )
    }

    private static func boundedMetadata(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        PDFDisplayText.bounded(value, maximumBytes: maximumBytes)
    }
}
