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
        return try await admission.withPermit {
            let opened = try VaultFileInspector.snapshot(
                target,
                maximumBytes: target.format.maximumFileBytes
            )
            return try readAdmitted(
                target: target,
                snapshot: FileSnapshot(
                    data: opened.data,
                    modifiedDate: opened.metadata.modificationDate
                ),
                pageNumbers: pageNumbers
            )
        }
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

    /// Returns bounded document metadata without rendering or extracting page content.
    func metadata(
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) async throws -> FileReadMetadata {
        try await admission.withPermit {
            try metadataAdmitted(target: target, snapshot: snapshot)
        }
    }

    /// The catalog uses this permit around snapshot capture and its admitted handlers.
    /// Direct reads acquire PDF admission before the vault lease. Search releases its
    /// vault read lease before taking this same PDF permit.
    func withPermit<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await admission.withPermit(operation)
    }

    /// Only a catalog binding holding this reader's permit may call this entry point.
    func readAdmitted(
        target: ReadableFileTarget,
        snapshot: FileSnapshot,
        options: ReadFileOptions
    ) throws -> [RenderedPDFPage] {
        try readAdmitted(target: target, snapshot: snapshot, pageNumbers: Self.pageNumbers(from: options))
    }

    /// Only a catalog binding holding this reader's permit may call this entry point.
    func metadataAdmitted(
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) throws -> FileReadMetadata {
        try Task.checkCancellation()
        guard let document = PDFDocument(data: snapshot.data) else {
            throw PDFReadError.cannotOpenPDF(target.relativePath)
        }
        let attributes = document.documentAttributes
        var incomplete = Set<FileMetadataField>()
        let title = FileMetadataTextBounds.display(
            attributes?[PDFDocumentAttribute.titleAttribute] as? String,
            field: .title,
            incomplete: &incomplete
        )
        let author = FileMetadataTextBounds.display(
            attributes?[PDFDocumentAttribute.authorAttribute] as? String,
            field: .author,
            incomplete: &incomplete
        )
        let labelLimit = min(
            document.pageCount,
            FileMetadataLimits.maximumPDFPageLabels
        )
        var labels: [String] = []
        labels.reserveCapacity(labelLimit)
        for index in 0..<labelLimit {
            try Task.checkCancellation()
            labels.append(FileMetadataTextBounds.display(
                document.page(at: index)?.label,
                field: .pageLabels,
                incomplete: &incomplete
            ) ?? "")
        }

        if document.pageCount > labelLimit { incomplete.insert(.pageLabels) }
        var outline: [PDFOutlineMetadataEntry] = []
        var outlineTruncated = false
        if let root = document.outlineRoot {
            try Self.collectOutline(
                root,
                document: document,
                depth: 0,
                result: &outline,
                truncated: &outlineTruncated,
                incomplete: &incomplete
            )
        }
        if outlineTruncated { incomplete.insert(.outline) }
        return FileReadMetadata(
            format: .pdf,
            byteCount: snapshot.data.count,
            modifiedAt: snapshot.modifiedDate.map(Self.timestamp),
            title: title,
            tags: nil,
            wordCount: nil,
            outgoingLinkTargets: nil,
            author: author,
            pageCount: document.pageCount,
            pageLabels: labels,
            pageLabelsTruncated: document.pageCount > labelLimit,
            outline: outline,
            outlineTruncated: outlineTruncated,
            incompleteFields: incomplete.sorted { $0.rawValue < $1.rawValue }
        )
    }

    private static func collectOutline(
        _ parent: PDFOutline,
        document: PDFDocument,
        depth: Int,
        result: inout [PDFOutlineMetadataEntry],
        truncated: inout Bool,
        incomplete: inout Set<FileMetadataField>
    ) throws {
        guard depth < FileMetadataLimits.maximumPDFOutlineDepth else {
            if parent.numberOfChildren > 0 { truncated = true }
            return
        }
        for index in 0..<parent.numberOfChildren {
            try Task.checkCancellation()
            guard result.count < FileMetadataLimits.maximumPDFOutlineEntries else {
                truncated = true
                return
            }
            guard let child = parent.child(at: index) else { continue }
            let page = child.destination?.page.map { document.index(for: $0) + 1 }
            result.append(PDFOutlineMetadataEntry(
                label: FileMetadataTextBounds.display(
                    child.label,
                    field: .outline,
                    incomplete: &incomplete
                ) ?? "",
                page: page,
                depth: depth
            ))
            try collectOutline(
                child,
                document: document,
                depth: depth + 1,
                result: &result,
                truncated: &truncated,
                incomplete: &incomplete
            )
            if truncated && result.count >= FileMetadataLimits.maximumPDFOutlineEntries {
                return
            }
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        return formatter.string(from: date)
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
