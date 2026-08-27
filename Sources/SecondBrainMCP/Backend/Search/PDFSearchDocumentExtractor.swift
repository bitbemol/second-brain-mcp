import Foundation

/// A complete PDF could not be represented within the existing search bounds.
enum PDFSearchExtractionError: Error, Sendable {
    case invalidPageCount(Int)
    case missingPage(Int)
    case pageTextTooLarge(bytes: Int, limit: Int)
    case documentTextTooLarge(bytes: Int, limit: Int)
}

/// Produces one searchable atom per physical PDF page and caches derived text.
struct PDFSearchAtomProvider: SearchAtomProvider {
    typealias DocumentOpener = @Sendable (Data) -> (any PDFSearchTextDocument)?

    private static let maximumPageTextBytes = 2 * 1_024 * 1_024
    private static let maximumDocumentTextBytes = 64 * 1_024 * 1_024

    private let cache: PDFSearchCache
    private let admission: PDFReadAdmission
    private let openDocument: DocumentOpener

    init(
        cacheRoot: URL,
        admission: PDFReadAdmission,
        openDocument: @escaping DocumentOpener = { PDFKitSearchTextDocument(data: $0) }
    ) {
        self.cache = PDFSearchCache(root: cacheRoot)
        self.admission = admission
        self.openDocument = openDocument
    }

    func atoms(
        for target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) async throws -> [SearchAtom] {
        try await atoms(for: target, snapshot: snapshot, budget: SearchWorkBudget())
    }

    func atoms(
        for target: ReadableFileTarget,
        snapshot: FileSnapshot,
        budget: SearchWorkBudget
    ) async throws -> [SearchAtom] {
        try await atoms(for: target, loadSnapshot: { snapshot }, budget: budget)
    }

    func atoms(
        for target: ReadableFileTarget,
        loadSnapshot: @escaping @Sendable () async throws -> FileSnapshot,
        budget: SearchWorkBudget
    ) async throws -> [SearchAtom] {
        let texts: [String] = try await admission.withPermit {
            // Both raw materialization and PDF extraction share the same admission.
            let snapshot = try await loadSnapshot()
            return try await self.pageTexts(for: target, snapshot: snapshot, budget: budget)
        }
        return texts.enumerated().map { index, text in
            SearchAtom(
                locator: VaultSearchResult(
                    path: target.relativePath,
                    format: .pdf,
                    page: index + 1
                ),
                text: text,
                metadata: nil
            )
        }
    }

    private func pageTexts(
        for target: ReadableFileTarget,
        snapshot: FileSnapshot,
        budget: SearchWorkBudget
    ) async throws -> [String] {
        do {
            return try cache.pages(
                path: target.relativePath,
                revision: snapshot.revision.rawValue,
                beforePage: { try budget.consumeAtoms() }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VaultSearchRequestError {
            throw error
        } catch {
            // Derived data is optional; unavailable/corrupt entries are misses.
        }

        try Task.checkCancellation()
        guard let document = openDocument(snapshot.data) else {
            throw SearchAtomProviderError.invalidPDF(target.relativePath)
        }
        let pages = try await extractPages(from: document, budget: budget)
        try Task.checkCancellation()
        do {
            try cache.store(
                pages,
                path: target.relativePath,
                revision: snapshot.revision.rawValue
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Cache persistence cannot hide successfully extracted source text.
        }
        return pages
    }

    /// The document owns per-page framework scopes; the PDF permit covers every awaited page.
    private nonisolated(nonsending) func extractPages(
        from document: any PDFSearchTextDocument,
        budget: SearchWorkBudget
    ) async throws -> [String] {
        let pageCount = document.pageCount
        guard (0...SearchRequestLimits.maximumAtoms).contains(pageCount) else {
            throw PDFSearchExtractionError.invalidPageCount(pageCount)
        }
        var pages: [String] = []
        pages.reserveCapacity(pageCount)
        var totalBytes = 0
        for index in 0..<pageCount {
            try budget.consumeAtoms()
            guard let text = try await document.text(at: index) else {
                throw PDFSearchExtractionError.missingPage(index + 1)
            }
            try Task.checkCancellation()
            let bytes = text.utf8.count
            guard bytes <= Self.maximumPageTextBytes else {
                throw PDFSearchExtractionError.pageTextTooLarge(
                    bytes: bytes, limit: Self.maximumPageTextBytes
                )
            }
            guard bytes <= Self.maximumDocumentTextBytes - totalBytes else {
                throw PDFSearchExtractionError.documentTextTooLarge(
                    bytes: totalBytes + bytes, limit: Self.maximumDocumentTextBytes
                )
            }
            totalBytes += bytes
            pages.append(text)
        }
        return pages
    }

}
