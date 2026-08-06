import Foundation

/// Validates and reads CSV while preserving the caller's exact representation.
struct CSVFileOperations: Sendable {
    /// Validates CSV bytes and reports their dimensions before generic creation.
    func prepareCreate(
        _ input: TextFileCreateInput,
        target: WritableFileTarget
    ) throws -> PreparedFileWrite {
        try Self.validateSize(input.data.count, path: target.relativePath)
        let text = try TextFileSupport.stringPreservingByteOrderMark(
            from: input.data
        )
        let inspection = try CSVDocumentInspector.inspect(text)
        return PreparedFileWrite(
            data: input.data,
            output: .text(
                "Created \(target.relativePath) "
                    + "(\(inspection.rowCount) rows × \(inspection.columnCount) columns)"
            )
        )
    }

    /// Returns complete validated CSV text without normalizing its line endings.
    func read(
        _ request: ReadFileRequest,
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) throws -> FileOperationOutput {
        try Self.validateSize(snapshot.data.count, path: target.relativePath)
        let text = try TextFileSupport.stringPreservingByteOrderMark(
            from: snapshot.data
        )
        _ = try CSVDocumentInspector.inspect(text)
        return .text(text)
    }

    /// Applies replacement, row append, or exact patches and validates the result.
    func prepareUpdate(
        _ request: UpdateFileRequest,
        target: WritableFileTarget,
        snapshot: FileSnapshot
    ) throws -> PreparedFileWrite {
        let existing = try TextFileSupport.stringPreservingByteOrderMark(
            from: snapshot.data
        )
        let updated: String
        switch request.mode {
        case .replace:
            guard let content = request.content else {
                throw TextFileSupport.TextError.missingContent
            }
            updated = content
        case .append:
            guard let content = request.content else {
                throw TextFileSupport.TextError.missingContent
            }
            updated = Self.appendingRows(content, to: existing)
        case .patch:
            updated = try TextFileSupport.apply(
                request.replacements,
                to: existing
            )
        }

        let data = Data(updated.utf8)
        try Self.validateSize(data.count, path: target.relativePath)
        let inspection = try CSVDocumentInspector.inspect(updated)
        return PreparedFileWrite(
            data: data,
            output: .text(
                "Updated \(target.relativePath) (\(request.mode.rawValue); "
                    + "\(inspection.rowCount) rows × \(inspection.columnCount) columns)"
            )
        )
    }

    /// Appends logical rows using only the CR/LF separators understood by CSV.
    private static func appendingRows(_ content: String, to original: String) -> String {
        guard !original.isEmpty, !content.isEmpty else { return original + content }
        let originalEndsRecord = original.last == "\r" || original.last == "\n"
        let contentStartsRecord = content.first == "\r" || content.first == "\n"
        guard !originalEndsRecord, !contentStartsRecord else {
            return original + content
        }
        return original + preferredRecordSeparator(in: original) + content
    }

    /// Preserves an existing table's record-ending convention when detectable.
    private static func preferredRecordSeparator(in text: String) -> String {
        if text.contains("\r\n") { return "\r\n" }
        if text.contains("\n") { return "\n" }
        if text.contains("\r") { return "\r" }
        return "\n"
    }

    private static func validateSize(_ bytes: Int, path: String) throws {
        try FileResourcePolicy.validate(
            bytes: bytes,
            format: .csv,
            path: path
        )
    }
}
