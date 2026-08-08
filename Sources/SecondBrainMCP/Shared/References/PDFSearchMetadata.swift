/// Search-time text availability for a PDF reference.
enum PDFTextExtractionStatus: String, Codable, CaseIterable, Sendable {
    /// Only filename or document metadata was needed; page text was not inspected.
    case metadataOnly = "metadata_only"
    /// Every page allowed by the search ceilings was extracted.
    case extracted
    /// Some pages, page text, or locator metadata were unavailable or omitted.
    case partial
    /// PDFKit opened the document but exposed no searchable text.
    case noExtractableText = "no_extractable_text"
    /// The document is locked and its page text is unavailable.
    case locked
    /// Search could index only filename metadata because the PDF exceeded its byte cap.
    case contentSkippedFileBytes = "content_skipped_file_bytes"
    /// PDFKit could not open the bounded snapshot.
    case cannotOpen = "cannot_open"
    /// The derived persistent text index could not safely answer this request.
    case indexUnavailable = "index_unavailable"
}

/// Coarse PDF page role used to keep navigational pages below body evidence.
enum PDFSearchPageKind: String, Codable, CaseIterable, Sendable {
    /// Substantive page content.
    case body
    /// Table-of-contents navigation page.
    case tableOfContents = "table_of_contents"
    /// Back-of-book index page.
    case index
    /// Bibliography or references page.
    case bibliography
    /// Glossary page.
    case glossary
}
