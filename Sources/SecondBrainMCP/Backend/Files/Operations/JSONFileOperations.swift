import Foundation

/// Validates general JSON while preserving the caller's exact representation.
///
/// JSON is parsed only to prove validity. Creation and updates persist the
/// original UTF-8 bytes instead of re-serializing them, so whitespace, key
/// ordering, number spelling, and top-level scalar values remain unchanged.
struct JSONFileOperations: Sendable {
    /// A payload is UTF-8 text but not one complete JSON value.
    struct InvalidJSON: Error, CustomStringConvertible, Sendable {
        /// Stable diagnostic returned without exposing Foundation parser details.
        var description: String { "File is not valid JSON" }
    }

    /// Validates JSON bytes before generic creation.
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

    /// Returns a complete, validated JSON document without normalization.
    func read(
        _ request: ReadFileRequest,
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) throws -> FileOperationOutput {
        try Self.validate(snapshot.data, path: target.relativePath)
        return .text(
            try TextFileSupport.stringPreservingByteOrderMark(from: snapshot.data)
        )
    }

    /// Applies replacement or exact text patches and validates the final JSON.
    ///
    /// Append is deliberately unsupported because concatenating two JSON values
    /// does not produce one valid JSON document.
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
        case .patch:
            updated = try TextFileSupport.apply(
                request.replacements,
                to: existing
            )
        case .append:
            throw FileRoutingError.operationNotSupported(
                format: .json,
                operation: .update,
                area: .notes
            )
        }

        let data = Data(updated.utf8)
        try Self.validate(data, path: target.relativePath)
        return PreparedFileWrite(
            data: data,
            output: .text("Updated \(target.relativePath) (\(request.mode.rawValue))")
        )
    }

    /// Accepts one bounded strict JSON value, including a top-level scalar.
    private static func validate(_ data: Data, path: String) throws {
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
