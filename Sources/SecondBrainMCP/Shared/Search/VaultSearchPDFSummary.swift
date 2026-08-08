/// Aggregate PDF extraction facts, including PDFs that produced no result.
struct VaultSearchPDFSummary: Codable, Equatable, Sendable {
    /// PDFs admitted for metadata or page-text evaluation.
    let examinedFileCount: Int
    /// PDFs completely evaluated without inspecting page text.
    let metadataOnlyFileCount: Int
    /// PDFs whose allowed pages yielded a complete text projection.
    let extractedFileCount: Int
    /// PDFs whose page or text ceilings omitted content.
    let partialFileCount: Int
    /// PDFs opened successfully but exposing no text.
    let noExtractableTextFileCount: Int
    /// Locked, unreadable, or search-byte-limited PDFs.
    let unavailableFileCount: Int
    /// Broad search never performs implicit OCR.
    let ocrPerformed: Bool

    /// Summary for a request that examined no PDF references.
    static let empty = VaultSearchPDFSummary(
        examinedFileCount: 0,
        metadataOnlyFileCount: 0,
        extractedFileCount: 0,
        partialFileCount: 0,
        noExtractableTextFileCount: 0,
        unavailableFileCount: 0,
        ocrPerformed: false
    )
}
