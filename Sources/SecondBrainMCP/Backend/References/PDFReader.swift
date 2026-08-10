import Foundation
import PDFKit

/// Opens a PDF snapshot and returns only requested physical pages.
struct PDFReader: Sendable {
    private let admission: PDFReadAdmission

    /// Creates a PDF reader with bounded expensive-read admission.
    init(admission: PDFReadAdmission = PDFReadAdmission()) {
        self.admission = admission
    }

    /// Reads one bounded physical-page selection. With no selector, page 1 is read.
    func read(
        target: ReadableFileTarget,
        options: ReadFileOptions = .default
    ) async throws -> [RenderedPDFPage] {
        let pageNumbers = try Self.pageNumbers(from: options)
        let opened = try VaultFileInspector.snapshot(
            target,
            maximumBytes: target.format.maximumFileBytes
        )
        return try await read(
            target: target,
            snapshot: FileSnapshot(
                data: opened.data,
                modifiedDate: opened.metadata.modificationDate
            ),
            pageNumbers: pageNumbers
        )
    }

    /// Renders physical pages exclusively from the immutable service snapshot.
    func read(
        target: ReadableFileTarget,
        snapshot: FileSnapshot,
        options: ReadFileOptions = .default
    ) async throws -> [RenderedPDFPage] {
        try await read(
            target: target,
            snapshot: snapshot,
            pageNumbers: Self.pageNumbers(from: options)
        )
    }

    private func read(
        target: ReadableFileTarget,
        snapshot: FileSnapshot,
        pageNumbers: [Int]
    ) async throws -> [RenderedPDFPage] {
        try await admission.withPermit {
            try readAdmitted(
                target: target,
                snapshot: snapshot,
                pageNumbers: pageNumbers
            )
        }
    }

    private func readAdmitted(
        target: ReadableFileTarget,
        snapshot: FileSnapshot,
        pageNumbers: [Int]
    ) throws -> [RenderedPDFPage] {
        try Task.checkCancellation()
        guard let document = PDFDocument(data: snapshot.data) else {
            throw PDFReadError.cannotOpenPDF(target.relativePath)
        }
        for page in pageNumbers where page > document.pageCount {
            throw PDFReadError.pageOutOfBounds(
                page: page,
                totalPages: document.pageCount
            )
        }
        return try PDFPageRenderer.renderPages(
            in: document,
            pageNumbers: pageNumbers
        )
    }

    private static func pageNumbers(
        from options: ReadFileOptions
    ) throws -> [Int] {
        let selectorCount = [
            options.page != nil,
            options.pages != nil,
            options.pageRange != nil,
        ].count(where: { $0 })
        guard selectorCount <= 1 else {
            throw PDFReadError.invalidSelection(
                "provide only one of page, pages, or page_range"
            )
        }

        if let page = options.page {
            return try validate([page])
        }
        if let pages = options.pages {
            guard !pages.isEmpty else {
                throw PDFReadError.invalidSelection("pages cannot be empty")
            }
            return try validate(pages)
        }
        if let range = options.pageRange {
            return try pages(in: range)
        }
        return [1]
    }

    private static func validate(_ pages: [Int]) throws -> [Int] {
        guard pages.count <= FileReadRequestLimits.maximumPDFPagesPerRead else {
            throw PDFReadError.invalidSelection(
                "at most \(FileReadRequestLimits.maximumPDFPagesPerRead) pages are allowed"
            )
        }
        guard pages.allSatisfy({ $0 > 0 }) else {
            throw PDFReadError.invalidSelection(
                "physical pages must be positive one-based integers"
            )
        }
        guard Set(pages).count == pages.count else {
            throw PDFReadError.invalidSelection("pages must be unique")
        }
        return pages
    }

    private static func pages(in rawRange: String) throws -> [Int] {
        let range = rawRange.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !range.isEmpty,
              range.utf8.count <= FileReadRequestLimits.maximumPDFPageRangeBytes else {
            throw PDFReadError.invalidSelection(
                "page_range must use at most \(FileReadRequestLimits.maximumPDFPageRangeBytes) UTF-8 bytes"
            )
        }
        let parts = range.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = Int(parts[0]),
              let end = Int(parts[1]),
              start > 0,
              end >= start else {
            throw PDFReadError.invalidSelection(
                "page_range must be an inclusive positive range such as 7-10"
            )
        }
        let (distance, overflow) = end.subtractingReportingOverflow(start)
        guard !overflow,
              distance < FileReadRequestLimits.maximumPDFPagesPerRead else {
            throw PDFReadError.invalidSelection(
                "page_range may contain at most \(FileReadRequestLimits.maximumPDFPagesPerRead) pages"
            )
        }
        return Array(start...end)
    }
}
