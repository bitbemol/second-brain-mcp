import Foundation
import PDFKit

/// Builds bounded page-aware search projections from immutable PDF snapshots.
enum PDFSearchDocumentExtractor {
    static func extract(
        data: Data,
        path: String,
        maximumPages: Int,
        maximumTextBytes: Int,
        maximumMetadataCharacters: Int,
        maximumMetadataBytes: Int
    ) throws -> ExtractedSearchDocument {
        try Task.checkCancellation()
        guard let document = PDFDocument(data: data) else {
            return metadataOnly(
                path: path,
                status: .cannotOpen,
                maximumMetadataCharacters: maximumMetadataCharacters,
                maximumMetadataBytes: maximumMetadataBytes
            )
        }
        let title = try title(
            from: document,
            path: path,
            maximumCharacters: maximumMetadataCharacters,
            maximumBytes: maximumMetadataBytes
        )
        guard !document.isLocked else {
            return makeDocument(
                path: path,
                title: title.value,
                sections: [],
                status: .locked,
                truncatedFields: Set([SearchField.content]).union(
                    title.truncated ? [.title] : []
                )
            )
        }

        let retainedPages = min(max(document.pageCount, 0), max(maximumPages, 0))
        var sections: [SearchSection] = []
        sections.reserveCapacity(min(retainedPages, 256))
        var retainedTextBytes = 0
        var stoppedForText = false
        var unavailablePage = false
        var emptyPageCount = 0
        var locatorLimited = false

        for index in 0..<retainedPages {
            try Task.checkCancellation()
            let remainingTextBytes = max(maximumTextBytes - retainedTextBytes, 0)
            let projection: (
                text: String,
                label: String?,
                exceedsLimit: Bool,
                labelTruncated: Bool
            )? = autoreleasepool {
                guard let page = document.page(at: index) else { return nil }
                guard page.numberOfCharacters <= remainingTextBytes else {
                    return ("", nil, true, false)
                }
                var text = page.string ?? ""
                text.makeContiguousUTF8()
                let label = page.label.map {
                    PDFDisplayText.bounded(
                        $0,
                        maximumCharacters: .max,
                        maximumBytes: SearchRequestLimits.maximumLocatorBytes
                    )
                }
                return (
                    text,
                    label?.value,
                    false,
                    label?.truncated ?? false
                )
            }
            guard let projection else {
                unavailablePage = true
                continue
            }
            if projection.exceedsLimit {
                stoppedForText = true
                break
            }
            let retainedLabel: String?
            if projection.labelTruncated {
                locatorLimited = true
                retainedLabel = nil
            } else if let label = projection.label, !label.isEmpty {
                try SensitiveContentPolicy.validate(
                    Data(label.utf8),
                    format: .markdown,
                    path: path
                )
                retainedLabel = label
            } else {
                retainedLabel = nil
            }
            let rawByteCount = projection.text.utf8.count
            guard rawByteCount <= remainingTextBytes else {
                stoppedForText = true
                break
            }
            retainedTextBytes += rawByteCount
            let text = projection.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else {
                emptyPageCount += 1
                continue
            }
            try SensitiveContentPolicy.validate(
                Data(text.utf8),
                format: .markdown,
                path: path
            )
            let physicalPage = index + 1
            let printedPage = retainedLabel == String(physicalPage)
                ? nil : retainedLabel
            sections.append(SearchSection(
                heading: nil,
                location: nil,
                content: text,
                lineStart: 1,
                lineEnd: TextLineScanner.lineCount(in: text),
                physicalPage: physicalPage,
                printedPage: printedPage,
                pdfPageKind: PDFPageClassifier.kind(for: text)
            ))
        }

        let pageLimited = retainedPages < document.pageCount
        let missingTextInMixedDocument = !sections.isEmpty && emptyPageCount > 0
        let isPartial = pageLimited || stoppedForText || unavailablePage
            || locatorLimited || missingTextInMixedDocument
        let status: PDFTextExtractionStatus
        if isPartial {
            status = .partial
        } else if sections.isEmpty {
            status = .noExtractableText
        } else {
            status = .extracted
        }
        var truncatedFields: Set<SearchField> = []
        if title.truncated { truncatedFields.insert(.title) }
        if isPartial { truncatedFields.insert(.content) }
        return makeDocument(
            path: path,
            title: title.value,
            sections: sections,
            status: status,
            truncatedFields: truncatedFields
        )
    }

    /// Extracts only the PDF's bounded title metadata without enumerating pages.
    static func extractMetadata(
        data: Data,
        path: String,
        maximumMetadataCharacters: Int,
        maximumMetadataBytes: Int
    ) throws -> ExtractedSearchDocument {
        try Task.checkCancellation()
        guard let document = PDFDocument(data: data) else {
            return metadataOnly(
                path: path,
                status: .cannotOpen,
                maximumMetadataCharacters: maximumMetadataCharacters,
                maximumMetadataBytes: maximumMetadataBytes
            )
        }
        let title = try title(
            from: document,
            path: path,
            maximumCharacters: maximumMetadataCharacters,
            maximumBytes: maximumMetadataBytes
        )
        return makeDocument(
            path: path,
            title: title.value,
            sections: [],
            status: .metadataOnly,
            truncatedFields: Set([SearchField.content]).union(
                title.truncated ? [.title] : []
            )
        )
    }

    /// Builds a filename-only projection when opening the PDF is unnecessary
    /// or impossible, recording which uninspected fields remain incomplete.
    static func metadataOnly(
        path: String,
        status: PDFTextExtractionStatus,
        maximumMetadataCharacters: Int,
        maximumMetadataBytes: Int
    ) -> ExtractedSearchDocument {
        let title = bounded(
            nil,
            fallback: MarkdownSupport.titleFromFilename(
                (path as NSString).lastPathComponent
            ),
            maximumCharacters: maximumMetadataCharacters,
            maximumBytes: maximumMetadataBytes
        )
        var truncatedFields: Set<SearchField> = [.content]
        if status == .cannotOpen || status == .contentSkippedFileBytes {
            truncatedFields.insert(.title)
        }
        if title.truncated { truncatedFields.insert(.title) }
        return makeDocument(
            path: path,
            title: title.value,
            sections: [],
            status: status,
            truncatedFields: truncatedFields
        )
    }

    private static func title(
        from document: PDFDocument,
        path: String,
        maximumCharacters: Int,
        maximumBytes: Int
    ) throws -> (value: String, truncated: Bool) {
        let title = boundedTitle(
            document.documentAttributes?[PDFDocumentAttribute.titleAttribute]
                as? String,
            path: path,
            maximumCharacters: maximumCharacters,
            maximumBytes: maximumBytes
        )
        try SensitiveContentPolicy.validate(
            Data(title.value.utf8),
            format: .markdown,
            path: path
        )
        return title
    }

    private static func makeDocument(
        path: String,
        title: String,
        sections: [SearchSection],
        status: PDFTextExtractionStatus,
        truncatedFields: Set<SearchField>
    ) -> ExtractedSearchDocument {
        ExtractedSearchDocument(
            document: SearchDocument(
                path: path,
                format: .pdf,
                title: title,
                tags: [],
                sections: sections,
                pdfTextExtractionStatus: status
            ),
            truncatedFields: truncatedFields
        )
    }

    private static func bounded(
        _ value: String?,
        fallback: String,
        maximumCharacters: Int,
        maximumBytes: Int
    ) -> (value: String, truncated: Bool) {
        let source = value.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        let result = PDFDisplayText.bounded(
            source,
            maximumCharacters: maximumCharacters,
            maximumBytes: maximumBytes
        )
        return (result.value, result.truncated)
    }

    private static func boundedTitle(
        _ value: String?,
        path: String,
        maximumCharacters: Int,
        maximumBytes: Int
    ) -> (value: String, truncated: Bool) {
        var sourceWasTruncated = false
        if let value, !value.isEmpty {
            let bounded = PDFDisplayText.bounded(
                value,
                maximumCharacters: maximumCharacters,
                maximumBytes: maximumBytes
            )
            let trimmed = bounded.value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty {
                return (trimmed, bounded.truncated)
            }
            sourceWasTruncated = bounded.truncated
        }
        let fallback = bounded(
            nil,
            fallback: MarkdownSupport.titleFromFilename(
                (path as NSString).lastPathComponent
            ),
            maximumCharacters: maximumCharacters,
            maximumBytes: maximumBytes
        )
        return (fallback.value, fallback.truncated || sourceWasTruncated)
    }
}
