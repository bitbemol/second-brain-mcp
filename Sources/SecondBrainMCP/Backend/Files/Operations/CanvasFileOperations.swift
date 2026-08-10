import Foundation

/// Validates JSON Canvas content during creation.
struct CanvasFileOperations: Sendable {
    /// Validates a centrally loaded canvas payload before generic persistence.
    func prepareCreate(
        _ input: TextFileCreateInput,
        target: WritableFileTarget
    ) throws -> PreparedFileWrite {
        try CanvasDocumentValidator.validate(jsonData: input.data)
        return PreparedFileWrite(
            data: input.data,
            output: .text("Created \(target.relativePath)")
        )
    }
}
