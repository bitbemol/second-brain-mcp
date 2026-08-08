import Foundation

/// Adapts PDF reference rendering and search to generic read output.
struct PDFFileOperations: Sendable {
    /// The read-only PDF component used to locate and render requested pages.
    let reader: PDFReader

    /// Renders selected PDF pages as paired extracted text and JPEG content.
    ///
    /// At most 20 pages are returned per request, even when the caller supplies a
    /// larger limit.
    func read(
        _ request: ReadFileRequest,
        target: ReadableFileTarget
    ) async throws -> FileOperationOutput {
        let options = request.options
        let result = try await reader.read(
            target: target,
            page: options.page,
            pageRange: options.pageRange,
            bookPage: options.bookPage,
            query: options.query,
            maxPages: min(max(options.maxPages ?? 5, 1), 20)
        )
        guard !result.renderedPages.isEmpty else {
            if let status = result.queryStatus {
                return .text(
                    queryStatusText(status, path: target.relativePath)
                        + renderLimitStatusText(result)
                )
            }
            return .text(
                "No pages rendered from \(target.relativePath)"
                    + renderLimitStatusText(result)
            )
        }

        var contents: [VaultFileContent] = [
            .text("\(result.title) (\(result.totalPages) pages total)")
        ]
        for page in result.renderedPages {
            let label = page.bookLabel.map { " (book page: \($0))" } ?? ""
            contents.append(.text("--- PDF Page \(page.pageNumber)\(label) ---"))
            if let text = page.extractedText { contents.append(.text(text)) }
            contents.append(.image(data: page.jpegData, mimeType: "image/jpeg"))
        }
        if let outline = result.outline {
            let lines = outline.map { entry in
                String(repeating: "  ", count: min(entry.level, 2)) + "- \(entry.title) (page \(entry.pageNumber))"
            }
            contents.append(.text("Table of Contents\n" + lines.joined(separator: "\n")))
        }
        if let status = result.queryStatus {
            contents.append(.text(queryStatusText(status, path: target.relativePath)))
        }
        let renderingStatus = renderLimitStatusText(result)
        if !renderingStatus.isEmpty {
            contents.append(.text(renderingStatus.trimmingCharacters(
                in: .whitespacesAndNewlines
            )))
        }
        return FileOperationOutput(contents: contents)
    }

    private func queryStatusText(
        _ status: PDFTextSearchResult,
        path: String
    ) -> String {
        "PDF query status for \(path): "
            + "matching_page_count_lower_bound=\(status.matchingPageCountLowerBound), "
            + "more_matches_available=\(status.moreMatchesAvailable), "
            + "scanned_pages=\(status.scannedPageCount)/\(status.totalPageCount), "
            + "text_extraction_status=\(status.textExtractionStatus.rawValue), "
            + "rendered_page_count=\(status.renderedPageCount), "
            + "render_failure_count=\(status.renderFailureCount), "
            + "ocr_performed=\(status.ocrPerformed)"
    }

    private func renderLimitStatusText(_ result: PDFReadResult) -> String {
        guard result.renderFailureCount > 0
                || result.renderLimitOmissionCount > 0
                || result.renderedTextOmissionCount > 0 else { return "" }
        return "\nPDF render limits: "
            + "render_failure_count=\(result.renderFailureCount), "
            + "payload_omission_count=\(result.renderLimitOmissionCount), "
            + "text_omission_count=\(result.renderedTextOmissionCount)"
    }
}
