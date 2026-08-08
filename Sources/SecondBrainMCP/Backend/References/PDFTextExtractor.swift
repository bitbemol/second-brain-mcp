import PDFKit

/// Stateless full-document search for the PDF read operation.
enum PDFTextExtractor {
    private struct RankedPage {
        let page: Int
        let score: Double
    }

    /// Scans a bounded number of pages and ranks substantive body passages
    /// ahead of tables of contents, indexes, bibliographies, and glossaries.
    static func rankedSearchDocument(
        _ document: PDFDocument,
        query: String,
        maxResults: Int = 10,
        maximumScannedPages: Int = 2_000,
        maximumTextBytes: Int = FileReadRequestLimits.maximumPDFQueryTextBytes,
        maximumOccurrencesPerPage: Int = FileReadRequestLimits
            .maximumPDFOccurrencesPerPage,
        maximumOccurrencesPerRequest: Int = FileReadRequestLimits
            .maximumPDFOccurrencesPerRequest
    ) throws -> PDFTextSearchResult {
        guard maxResults > 0, maximumScannedPages > 0, !query.isEmpty else {
            return PDFTextSearchResult(
                pages: [],
                matchingPageCountLowerBound: 0,
                scannedPageCount: 0,
                totalPageCount: document.pageCount,
                moreMatchesAvailable: false,
                textExtractionStatus: .noExtractableText,
                ocrPerformed: false
            )
        }
        guard !document.isLocked else {
            return PDFTextSearchResult(
                pages: [],
                matchingPageCountLowerBound: 0,
                scannedPageCount: 0,
                totalPageCount: document.pageCount,
                moreMatchesAvailable: false,
                textExtractionStatus: .locked,
                ocrPerformed: false
            )
        }
        let scanned = min(document.pageCount, maximumScannedPages)
        var ranked: [RankedPage] = []
        var observedText = false
        var emptyPages = 0
        var unavailablePages = 0
        var evaluatedPages = 0
        var retainedTextBytes = 0
        var stoppedForText = false
        var stoppedForOccurrences = false
        var remainingOccurrences = max(maximumOccurrencesPerRequest, 0)
        for index in 0..<scanned {
            try Task.checkCancellation()
            guard remainingOccurrences > 0 else {
                stoppedForOccurrences = true
                break
            }
            let remainingTextBytes = max(maximumTextBytes - retainedTextBytes, 0)
            let projection: (text: String, exceedsLimit: Bool)? = autoreleasepool {
                guard let page = document.page(at: index) else { return nil }
                guard page.numberOfCharacters <= remainingTextBytes else {
                    return ("", true)
                }
                var text = page.string ?? ""
                text.makeContiguousUTF8()
                return (text, false)
            }
            guard let projection else {
                unavailablePages += 1
                continue
            }
            if projection.exceedsLimit {
                stoppedForText = true
                break
            }
            // Charge the complete detached page string, including whitespace.
            // Trimming first would let whitespace-heavy pages consume almost no
            // budget while still forcing PDFKit to materialize their full text.
            let rawText = projection.text
            let byteCount = rawText.utf8.count
            guard byteCount <= remainingTextBytes else {
                stoppedForText = true
                break
            }
            retainedTextBytes += byteCount
            evaluatedPages += 1
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                emptyPages += 1
                continue
            }
            observedText = true
            let occurrenceCount = try occurrences(
                of: query,
                in: text,
                maximum: min(maximumOccurrencesPerPage, remainingOccurrences)
            )
            guard occurrenceCount > 0 else { continue }
            remainingOccurrences -= occurrenceCount
            let kind = PDFPageClassifier.kind(for: text)
            let roleScore: Double
            switch kind {
            case .body: roleScore = 500
            case .bibliography: roleScore = 180
            case .glossary: roleScore = 150
            case .index: roleScore = 100
            case .tableOfContents: roleScore = 50
            }
            let density = min(
                Double(occurrenceCount) * 1_000 / Double(max(byteCount, 1)),
                50
            )
            ranked.append(RankedPage(
                page: index + 1,
                score: roleScore
                    + (Double(min(occurrenceCount, 20)) * 10) + density
            ))
            if remainingOccurrences == 0 {
                stoppedForOccurrences = true
                break
            }
        }
        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.page < $1.page
        }
        let scanWasPartial = scanned < document.pageCount
        let mixedMissingText = observedText && emptyPages > 0
        let extractionWasPartial = scanWasPartial || stoppedForText
            || stoppedForOccurrences
            || unavailablePages > 0 || mixedMissingText
        let status: PDFTextExtractionStatus
        if extractionWasPartial {
            status = .partial
        } else if observedText {
            status = .extracted
        } else {
            status = .noExtractableText
        }
        return PDFTextSearchResult(
            pages: ranked.prefix(maxResults).map(\.page),
            matchingPageCountLowerBound: ranked.count,
            scannedPageCount: evaluatedPages,
            totalPageCount: document.pageCount,
            moreMatchesAvailable: ranked.count > maxResults || extractionWasPartial,
            textExtractionStatus: status,
            ocrPerformed: false
        )
    }

    private static func occurrences(
        of query: String,
        in text: String,
        maximum: Int
    ) throws -> Int {
        guard maximum > 0 else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(
            of: query,
            options: .caseInsensitive,
            range: searchRange
        ) {
            count += 1
            if count.isMultiple(of: 1_024) { try Task.checkCancellation() }
            if count >= maximum { break }
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }
}
