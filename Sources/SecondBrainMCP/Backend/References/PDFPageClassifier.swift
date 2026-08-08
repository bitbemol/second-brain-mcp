import Foundation

/// Bounded page-role classification shared by direct and broad PDF search.
enum PDFPageClassifier {
    private static let maximumSampleCharacters = 16 * 1_024

    /// Classifies a page without splitting or retaining its complete text.
    static func kind(for text: String) -> PDFSearchPageKind {
        let sample = text.prefix(maximumSampleCharacters)
        let lines = sample.split(
            maxSplits: 80,
            omittingEmptySubsequences: true,
            whereSeparator: \.isNewline
        )
        let headings = lines.prefix(8).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if headings.contains(where: {
            $0 == "contents" || $0.hasPrefix("table of contents")
        }) {
            return .tableOfContents
        }
        if headings.contains(where: { $0 == "index" || $0.hasPrefix("index ") }) {
            return .index
        }
        if headings.contains(where: {
            $0 == "bibliography" || $0 == "references"
                || $0.hasPrefix("bibliography ")
        }) {
            return .bibliography
        }
        if headings.contains(where: {
            $0 == "glossary" || $0.hasPrefix("glossary ")
        }) {
            return .glossary
        }
        if lines.count(where: { $0.contains("...") }) >= 3 {
            return .tableOfContents
        }
        return .body
    }
}
