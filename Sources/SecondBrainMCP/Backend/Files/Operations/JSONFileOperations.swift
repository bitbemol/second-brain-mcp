import Foundation

/// Validates general JSON while preserving the caller's exact representation.
struct JSONFileOperations: Sendable {
    struct InvalidJSON: Error, CustomStringConvertible, CallerSafeError, Sendable {
        var description: String { "File is not valid JSON" }
        var callerSafeDescription: String { description }
    }

    func prepareCreate(
        _ input: TextFileCreateInput,
        target: WritableFileTarget
    ) throws -> PreparedFileWrite {
        try Self.validate(input.data, path: target.relativePath)
        return PreparedFileWrite(
            data: input.data,
            output: .text("Created \(target.relativePath)")
        )
    }

    /// Accepts one bounded strict JSON value, including a top-level scalar.
    static func validate(_ data: Data, path: String) throws {
        try FileResourcePolicy.validate(
            bytes: data.count,
            format: .json,
            path: path
        )
        do {
            try JSONSyntaxValidator.validate(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw InvalidJSON()
        }
    }
}
