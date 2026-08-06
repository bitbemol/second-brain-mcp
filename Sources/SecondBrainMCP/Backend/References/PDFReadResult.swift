/// Metadata and rendered content returned for one PDF read request.
struct PDFReadResult: Sendable {
    /// Document title from PDF metadata or the source filename.
    let title: String

    /// Total physical page count in the document.
    let totalPages: Int

    /// Pages selected and rendered for this request.
    let renderedPages: [RenderedPDFPage]

    /// Document bookmarks, when the PDF contains an outline.
    let outline: [PDFDocumentNavigation.OutlineEntry]?
}
