import Foundation

/// Validates CSV creation and supplies the format's record-aware append rule.
struct CSVFileOperations: Sendable {
    func prepareCreate(
        _ input: TextFileCreateInput,
        target: WritableFileTarget
    ) throws -> PreparedFileWrite {
        try Self.validate(input.data, path: target.relativePath)
        let text = try TextFileSupport.stringPreservingByteOrderMark(
            from: input.data
        )
        let inspection = try CSVDocumentInspector.inspect(text)
        return PreparedFileWrite(
            data: input.data,
            output: .text(
                "Created \(target.relativePath) "
                    + "(\(inspection.rowCount) rows × "
                    + "\(inspection.columnCount) columns)"
            )
        )
    }

    /// Appends logical rows using only the CR/LF separators understood by CSV.
    static func appendingRows(_ content: String, to original: String) -> String {
        guard !original.isEmpty, !content.isEmpty else {
            return original + content
        }
        let originalLast = original.unicodeScalars.last?.value
        let contentFirst = content.unicodeScalars.first?.value
        let originalEndsRecord = originalLast == 0x0D || originalLast == 0x0A
        let contentStartsRecord = contentFirst == 0x0D || contentFirst == 0x0A
        guard !originalEndsRecord, !contentStartsRecord else {
            return original + content
        }
        return original + preferredRecordSeparator(in: original) + content
    }

    static func validate(_ data: Data, path: String) throws {
        try FileResourcePolicy.validate(
            bytes: data.count,
            format: .csv,
            path: path
        )
        let text = try TextFileSupport.stringPreservingByteOrderMark(from: data)
        _ = try CSVDocumentInspector.inspect(text)
    }

    private static func preferredRecordSeparator(in text: String) -> String {
        if text.contains("\r\n") { return "\r\n" }
        if text.contains("\n") { return "\n" }
        if text.contains("\r") { return "\r" }
        return "\n"
    }
}
