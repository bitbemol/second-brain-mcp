/// Adapts physical PDF page reads to generic file output.
struct PDFFileOperations: Sendable {
    /// The read-only PDF component used to render requested pages.
    let reader: PDFReader

    /// Returns exactly one text block and one PNG image for each selected page.
    func read(
        _ request: ReadFileRequest,
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) async throws -> FileOperationOutput {
        let pages = try await reader.read(
            target: target,
            snapshot: snapshot,
            options: request.options
        )
        return Self.output(pages)
    }

    /// The factory pairs this handler with admission from the same reader.
    func readAdmitted(
        _ request: ReadFileRequest,
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) async throws -> FileOperationOutput {
        Self.output(try reader.readAdmitted(target: target, snapshot: snapshot, options: request.options))
    }

    /// Metadata uses the same admission owner as rendered content.
    func metadataAdmitted(
        _ request: ReadFileRequest,
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) async throws -> FileOperationOutput {
        .metadata(try reader.metadataAdmitted(target: target, snapshot: snapshot))
    }

    private static func output(_ pages: [RenderedPDFPage]) -> FileOperationOutput {
        var contents: [VaultFileContent] = []
        contents.reserveCapacity(pages.count * 2)
        for page in pages {
            let heading = "--- PDF Page \(page.pageNumber) ---"
            let text = page.text.isEmpty
                ? heading
                : heading + "\n" + page.text
            contents.append(.text(text))
            contents.append(.image(data: page.pngData, mimeType: "image/png"))
        }
        return FileOperationOutput(contents: contents)
    }
}
