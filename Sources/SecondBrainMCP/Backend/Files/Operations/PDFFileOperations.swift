import Foundation

/// Adapts PDF reference rendering to generic read output.
struct PDFFileOperations: Sendable {
    /// The read-only PDF component used to render requested pages.
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
            maxPages: min(max(options.maxPages ?? 5, 1), 20)
        )
        guard !result.renderedPages.isEmpty else {
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
        let renderingStatus = renderLimitStatusText(result)
        if !renderingStatus.isEmpty {
            contents.append(.text(renderingStatus.trimmingCharacters(
                in: .whitespacesAndNewlines
            )))
        }
        return FileOperationOutput(contents: contents)
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
