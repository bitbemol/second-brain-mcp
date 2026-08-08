import Foundation

/// Bounded page-role classification shared by direct and broad PDF search.
enum PDFPageClassifier {
    private static let maximumSampleCharacters = 16 * 1_024
    private static let maximumSampleLines = 80

    /// Classifies a page without splitting or retaining its complete text.
    static func kind(for text: String) -> PDFSearchPageKind {
        let sample = text.prefix(maximumSampleCharacters)
        let lines = sample.split(
            maxSplits: maximumSampleLines,
            omittingEmptySubsequences: true,
            whereSeparator: \.isNewline
        )
        let headings = lines.prefix(20).map {
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
        let projections = lines.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let dotLeaderCount = projections.count(where: { line in
            line.contains("...") || line.contains("…")
        })
        let trailingPageReferenceCount = projections.count(where: {
            looksLikeNavigationEntry($0)
        })
        let proseLineCount = projections.count(where: { line in
            line.count >= 120 || (
                line.count >= 70
                    && (line.hasSuffix(".") || line.hasSuffix("?")
                        || line.hasSuffix("!"))
            )
        })
        if dotLeaderCount >= 3 {
            return .tableOfContents
        }
        // Many publishers omit both a `Contents` heading and dot leaders. A
        // dense run of short title-plus-page-number lines is still navigation,
        // provided prose does not dominate the sampled page.
        if trailingPageReferenceCount >= 5,
           trailingPageReferenceCount * 2 >= projections.count,
           proseLineCount < trailingPageReferenceCount {
            return .tableOfContents
        }
        return .body
    }

    private static func looksLikeNavigationEntry(_ line: String) -> Bool {
        guard line.count <= 180 else { return false }
        let components = line.split(whereSeparator: \.isWhitespace)
        guard components.count >= 2, let tail = components.last else { return false }
        let token = tail.trimmingCharacters(in: CharacterSet(charactersIn: ".·"))
        guard isPageNumber(token) else { return false }

        let title = components.dropLast().joined(separator: " ")
        guard title.contains(where: \.isLetter) else { return false }
        // Avoid treating ordinary short sentences ending in a year/count as a
        // contents entry unless another strong navigation signal is present.
        return line.contains("...") || line.contains("…")
            || !title.hasSuffix(".")
    }

    private static func isPageNumber(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 8 else { return false }
        if isSinglePageNumber(token) { return true }
        let separators = CharacterSet(charactersIn: "-\u{2013}\u{2014}")
        let rangeParts = token.unicodeScalars.split(
            maxSplits: 1,
            omittingEmptySubsequences: false,
            whereSeparator: separators.contains
        )
        return rangeParts.count == 2
            && rangeParts.allSatisfy {
                isSinglePageNumber(String(String.UnicodeScalarView($0)))
            }
    }

    private static func isSinglePageNumber(_ token: String) -> Bool {
        if token.allSatisfy(\.isNumber) { return true }
        let roman = CharacterSet(charactersIn: "ivxlcdmIVXLCDM")
        return token.unicodeScalars.allSatisfy(roman.contains)
    }
}
