import Foundation
import PDFKit

/// Versioned extraction facts persisted by the derived PDF search index.
enum PDFSearchIndexContract {
    static let schemaVersion = 1
    static let extractorVersion = 1
    static let normalizerVersion = 1
    static let classifierVersion = 1
    static let sensitivePolicyVersion = 1
}

/// One validated page representation stored transactionally in the index.
struct IndexedPDFPage: Sendable {
    let physicalPage: Int
    let printedPage: String?
    let kind: PDFSearchPageKind
    let lineCount: Int
    let rawText: String
    let literalFolded: String
    let normalizedTerms: String
}

/// One bounded page candidate hydrated for the existing Swift matcher.
///
/// Folded and tokenized index representations stay inside SQLite; carrying
/// them into every query would triple candidate memory without affecting rank.
struct PDFIndexCandidatePage: Sendable {
    let physicalPage: Int
    let printedPage: String?
    let kind: PDFSearchPageKind
    let lineCount: Int
    let rawText: String
}

/// Complete bounded extraction outcome for one immutable PDF snapshot.
struct IndexedPDFExtraction: Sendable {
    let title: String
    let titleTruncated: Bool
    let pageCount: Int
    let pages: [IndexedPDFPage]
    let status: PDFTextExtractionStatus
}

/// Extracts a complete, validated document projection before any text is
/// allowed to enter SQLite or its WAL.
enum PDFIndexExtractor {
    static func extract(
        snapshotURL: URL,
        path: String,
        includePages: Bool,
        maximumPages: Int = 20_000,
        maximumTextBytes: Int = 64 * 1024 * 1024,
        maximumPageTextBytes: Int = 4 * 1024 * 1024,
        maximumMetadataCharacters: Int = 512,
        maximumMetadataBytes: Int = 2_048
    ) throws -> IndexedPDFExtraction {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: snapshotURL) else {
            return IndexedPDFExtraction(
                title: fallbackTitle(path),
                titleTruncated: false,
                pageCount: 0,
                pages: [],
                status: .cannotOpen
            )
        }
        let rawTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute]
            as? String
        let boundedSourceTitle = PDFDisplayText.bounded(
            rawTitle ?? "",
            maximumCharacters: maximumMetadataCharacters,
            maximumBytes: maximumMetadataBytes
        )
        let trimmedTitle = boundedSourceTitle.value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let fallbackBoundedTitle = trimmedTitle.isEmpty
            ? PDFDisplayText.bounded(
                fallbackTitle(path),
                maximumCharacters: maximumMetadataCharacters,
                maximumBytes: maximumMetadataBytes
            )
            : nil
        let titleValue = fallbackBoundedTitle?.value ?? trimmedTitle
        let titleWasTruncated = boundedSourceTitle.truncated
            || fallbackBoundedTitle?.truncated == true
        try SensitiveContentPolicy.validate(
            Data(titleValue.utf8),
            format: .markdown,
            path: path
        )
        guard includePages else {
            return IndexedPDFExtraction(
                title: titleValue,
                titleTruncated: titleWasTruncated,
                pageCount: max(document.pageCount, 0),
                pages: [],
                status: .metadataOnly
            )
        }
        guard !document.isLocked else {
            return IndexedPDFExtraction(
                title: titleValue,
                titleTruncated: titleWasTruncated,
                pageCount: max(document.pageCount, 0),
                pages: [],
                status: .locked
            )
        }

        let pageCount = max(document.pageCount, 0)
        let retainedCount = min(pageCount, max(maximumPages, 0))
        var pages: [IndexedPDFPage] = []
        pages.reserveCapacity(min(retainedCount, 512))
        var textBytes = 0
        var emptyPages = 0
        var unavailablePages = 0
        var limited = retainedCount < pageCount
        var allPageTextValidated = retainedCount == pageCount

        for index in 0..<retainedCount {
            try Task.checkCancellation()
            let remainingTextBytes = max(maximumTextBytes - textBytes, 0)
            let projection: (String, String?, Bool, Bool)? = autoreleasepool {
                guard let page = document.page(at: index) else { return nil }
                let pageByteLimit = min(
                    max(maximumPageTextBytes, 0),
                    remainingTextBytes
                )
                // Every character needs at least one UTF-8 byte. Avoid asking
                // PDFKit to materialize a page string that cannot possibly fit
                // the declared projection ceiling.
                guard page.numberOfCharacters <= pageByteLimit else {
                    return ("", nil, false, true)
                }
                let boundedText = PDFDisplayText.bounded(
                    page.string ?? "",
                    maximumCharacters: .max,
                    maximumBytes: pageByteLimit
                )
                var text = boundedText.value
                text.makeContiguousUTF8()
                let boundedLabel = page.label.map {
                    PDFDisplayText.bounded(
                        $0,
                        maximumCharacters: .max,
                        maximumBytes: SearchRequestLimits.maximumLocatorBytes
                    )
                }
                return (
                    text,
                    boundedLabel?.truncated == false
                        ? boundedLabel?.value.nilIfEmpty : nil,
                    boundedLabel?.truncated == true,
                    boundedText.truncated
                )
            }
            guard let projection else {
                unavailablePages += 1
                allPageTextValidated = false
                continue
            }
            guard !projection.3 else {
                limited = true
                allPageTextValidated = false
                break
            }
            let bytes = projection.0.utf8.count
            textBytes += bytes
            let text = projection.0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                emptyPages += 1
                continue
            }
            // Validation is intentionally complete before the returned page
            // array can be published by the database transaction.
            try SensitiveContentPolicy.validate(
                Data(text.utf8),
                format: .markdown,
                path: path
            )
            let physicalPage = index + 1
            if projection.2 { limited = true }
            let label = projection.1
            if let label {
                try SensitiveContentPolicy.validate(
                    Data(label.utf8),
                    format: .markdown,
                    path: path
                )
            }
            let printedPage = label == String(physicalPage) ? nil : label
            let literalFolded = text.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            let tokenization = try SearchTokenizer.boundedTokens(
                in: text,
                maximumTokens: 500_000,
                maximumTokenScalars: SearchResourceLimits.default.maximumTokenScalars
            )
            if tokenization.truncated { limited = true }
            let normalizedTerms = tokenization.tokens.map(\.normalized)
                .joined(separator: " ")
            pages.append(IndexedPDFPage(
                physicalPage: physicalPage,
                printedPage: printedPage,
                kind: PDFPageClassifier.kind(for: text),
                lineCount: TextLineScanner.lineCount(in: text),
                rawText: text,
                literalFolded: literalFolded,
                normalizedTerms: normalizedTerms
            ))
        }
        if unavailablePages > 0 { limited = true }
        if !pages.isEmpty, emptyPages > 0 { limited = true }
        let status: PDFTextExtractionStatus
        if limited {
            status = .partial
        } else if pages.isEmpty {
            status = .noExtractableText
        } else {
            status = .extracted
        }
        return IndexedPDFExtraction(
            title: titleValue,
            titleTruncated: titleWasTruncated,
            pageCount: pageCount,
            pages: allPageTextValidated ? pages : [],
            status: status
        )
    }

    private static func fallbackTitle(_ path: String) -> String {
        MarkdownSupport.titleFromFilename((path as NSString).lastPathComponent)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
