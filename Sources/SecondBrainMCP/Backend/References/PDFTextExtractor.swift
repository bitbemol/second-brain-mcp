import PDFKit

/// Stateless full-document search for the PDF read operation.
enum PDFTextExtractor {
    /// Finds unique one-based page numbers containing a case-insensitive query.
    ///
    /// - Parameters:
    ///   - document: An already-opened PDF document.
    ///   - query: Case-insensitive text to find in extracted page text.
    ///   - maxResults: Maximum number of unique pages to return.
    /// - Returns: Matching page numbers in physical document order.
    static func searchDocument(
        _ document: PDFDocument,
        query: String,
        maxResults: Int = 10
    ) -> [Int] {
        guard maxResults > 0, !query.isEmpty else { return [] }
        var results: [Int] = []

        for index in 0..<document.pageCount {
            guard results.count < maxResults else { break }
            // PDFKit's document-wide find API materializes every selection before
            // returning. Extracting one page at a time bounds memory and lets the
            // requested result limit stop work at its source.
            let matches = autoreleasepool {
                document.page(at: index)?.string?.range(
                    of: query,
                    options: .caseInsensitive
                ) != nil
            }
            if matches {
                results.append(index + 1)
            }
        }
        return results
    }
}
