import Foundation
import PDFKit

/// Reads page-label and bookmark navigation metadata from PDF documents.
enum PDFDocumentNavigation {
    /// Outline entry projected from a PDF bookmark.
    struct OutlineEntry: Sendable {
        /// Bookmark title.
        let title: String
        /// One-based physical destination page.
        let pageNumber: Int
        /// Outline depth: zero for chapters, one for sections, and two for subsections.
        let level: Int
    }

    /// Extracts useful printed page labels keyed by physical page number.
    ///
    /// Labels that only repeat every physical page number are omitted because
    /// they add no navigation information.
    ///
    /// - Parameter document: An already-opened PDF document.
    /// - Returns: Non-trivial labels keyed by one-based physical page, or `nil`.
    static func pageLabels(in document: PDFDocument) -> [Int: String]? {
        guard document.pageCount > 0 else { return nil }

        var labels: [Int: String] = [:]
        var allTrivial = true

        for index in 0..<document.pageCount {
            // PDFKit autoreleases page objects. Draining once per page prevents
            // large documents from retaining every page until the caller's pool.
            // Regression coverage simulates a 1,500-page PDF: removing this pool
            // leaves all 1,500 page objects alive at the end of the scan.
            autoreleasepool {
                guard let label = document.page(at: index)?.label else { return }
                let pageNumber = index + 1
                labels[pageNumber] = label
                if label != "\(pageNumber)" {
                    allTrivial = false
                }
            }
        }

        guard !allTrivial else { return nil }
        return labels.isEmpty ? nil : labels
    }

    /// Resolves a printed page label to its one-based physical page number.
    ///
    /// - Parameters:
    ///   - label: Printed label such as `xii` or `42`.
    ///   - labels: Printed labels keyed by physical page number.
    /// - Returns: Matching physical page number, or `nil`.
    static func resolvePage(label: String, in labels: [Int: String]) -> Int? {
        labels.first { $0.value == label }?.key
    }

    /// Resolves a printed label directly from a document without retaining all labels.
    ///
    /// The scan stops at the first match and drains PDFKit page objects after each
    /// comparison, keeping lookup work and memory proportional to the match position.
    ///
    /// - Parameters:
    ///   - label: Printed label such as `xii` or `42`.
    ///   - document: An already-opened PDF document.
    /// - Returns: Matching one-based physical page number, or `nil`.
    static func resolvePage(
        label: String,
        in document: PDFDocument,
        maximumPages: Int = 2_000
    ) throws -> Int? {
        let scannedPages = min(max(document.pageCount, 0), max(maximumPages, 0))
        for index in 0..<scannedPages {
            try Task.checkCancellation()
            let matches = autoreleasepool {
                document.page(at: index)?.label == label
            }
            if matches {
                return index + 1
            }
        }
        guard scannedPages == document.pageCount else {
            throw PDFReadError.pageLabelSearchIncomplete(
                maximumPages: maximumPages
            )
        }
        return nil
    }

    /// Extracts the document bookmark hierarchy to bounded depth and size.
    ///
    /// - Parameters:
    ///   - document: An already-opened PDF document.
    ///   - maximumEntries: Maximum bookmarks retained across the complete hierarchy.
    ///   - maximumVisitedNodes: Maximum bookmarks inspected, including malformed
    ///     entries that cannot be returned.
    /// - Returns: Chapter, section, and subsection entries, or `nil`.
    static func outline(
        in document: PDFDocument,
        maximumEntries: Int = 50,
        maximumVisitedNodes: Int = 500
    ) throws -> [OutlineEntry]? {
        guard maximumEntries > 0, maximumVisitedNodes > 0,
              let root = document.outlineRoot,
              root.numberOfChildren > 0 else {
            return nil
        }

        var entries: [OutlineEntry] = []
        var visitedNodes = 0
        try appendChildren(
            of: root,
            document: document,
            level: 0,
            maximumEntries: maximumEntries,
            maximumVisitedNodes: maximumVisitedNodes,
            visitedNodes: &visitedNodes,
            to: &entries
        )
        return entries.isEmpty ? nil : entries
    }

    private static func appendChildren(
        of parent: PDFOutline,
        document: PDFDocument,
        level: Int,
        maximumEntries: Int,
        maximumVisitedNodes: Int,
        visitedNodes: inout Int,
        to entries: inout [OutlineEntry]
    ) throws {
        for index in 0..<parent.numberOfChildren {
            try Task.checkCancellation()
            guard entries.count < maximumEntries,
                  visitedNodes < maximumVisitedNodes else { return }
            visitedNodes += 1
            guard let child = parent.child(at: index) else { continue }

            if let rawTitle = child.label,
               let page = child.destination?.page {
                let title = boundedMetadata(rawTitle)
                let pageIndex = document.index(for: page)
                if pageIndex != NSNotFound {
                    entries.append(
                        OutlineEntry(
                            title: title,
                            pageNumber: pageIndex + 1,
                            level: level
                        )
                    )
                }
            }

            if level < 2 {
                try appendChildren(
                    of: child,
                    document: document,
                    level: level + 1,
                    maximumEntries: maximumEntries,
                    maximumVisitedNodes: maximumVisitedNodes,
                    visitedNodes: &visitedNodes,
                    to: &entries
                )
            }
        }
    }

    private static func boundedMetadata(_ value: String) -> String {
        PDFDisplayText.bounded(value, maximumBytes: 512)
    }
}
