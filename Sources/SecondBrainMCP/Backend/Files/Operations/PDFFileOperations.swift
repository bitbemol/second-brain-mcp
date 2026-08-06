import Foundation

/// Adapts PDF reference rendering and search to generic read output.
struct PDFFileOperations: Sendable {
    /// The read-only PDF component used to locate and render requested pages.
    let reader: PDFReader

    /// Renders selected PDF pages as paired extracted text and JPEG content.
    ///
    /// At most 20 pages are returned per request, even when the caller supplies a
    /// larger limit.
    func read(_ request: ReadFileRequest, target: ReadableFileTarget) throws -> FileOperationOutput {
        let options = request.options
        let result = try reader.read(
            target: target,
            page: options.page,
            pageRange: options.pageRange,
            bookPage: options.bookPage,
            query: options.query,
            maxPages: min(max(options.maxPages ?? 5, 1), 20)
        )
        guard !result.renderedPages.isEmpty else {
            return .text("No pages rendered from \(target.relativePath)")
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
        return FileOperationOutput(contents: contents)
    }
}
