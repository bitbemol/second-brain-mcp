/// Converts a physical PDF page range into bounded, one-based page numbers.
enum PDFPageRangeParser {
    /// Parses an inclusive `start-end` range and applies document and result limits.
    ///
    /// Malformed ranges preserve the read operation's fallback behavior by selecting
    /// the first available pages. Non-positive limits and empty documents select no
    /// pages.
    ///
    /// - Parameters:
    ///   - range: Requested inclusive physical range in `start-end` form.
    ///   - totalPages: Number of physical pages in the PDF document.
    ///   - maximumPages: Maximum number of page numbers to return.
    /// - Returns: Bounded, one-based physical page numbers.
    static func pages(
        in range: String,
        totalPages: Int,
        maximumPages: Int
    ) -> [Int] {
        guard totalPages > 0, maximumPages > 0 else { return [] }

        let components = range.split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              let requestedStart = Int(components[0]),
              let requestedEnd = Int(components[1]) else {
            return Array(1...min(totalPages, maximumPages))
        }

        let start = max(1, requestedStart)
        guard start <= totalPages else { return [] }

        // Derive the cap from the remaining document length. This avoids integer
        // overflow even when a caller supplies Int.max as a page or result limit.
        let availablePages = totalPages - start + 1
        let pageCount = min(maximumPages, availablePages)
        let cappedEnd = start + pageCount - 1
        let end = min(requestedEnd, cappedEnd)

        guard start <= end else { return [] }
        return Array(start...end)
    }
}
