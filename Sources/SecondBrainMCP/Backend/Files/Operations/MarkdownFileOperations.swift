import Foundation

/// Prepares and reads Markdown notes while preserving generic storage semantics.
///
/// Creation adds minimal front matter when none is present. Updates support full
/// replacement, append, and exact single-match text replacements.
struct MarkdownFileOperations: Sendable {
    /// Injects front matter into validated Markdown bytes when none is present.
    ///
    /// - Parameters:
    ///   - input: Centrally validated bytes and note metadata.
    ///   - target: Validated destination used to derive the fallback title.
    /// - Returns: Markdown bytes ready for generic persistence.
    func prepareCreate(
        _ input: TextFileCreateInput,
        target: WritableFileTarget
    ) throws -> PreparedFileWrite {
        var text = try TextFileSupport.string(from: input.data)
        if !MarkdownSupport.hasFrontmatter(text) {
            let title = MarkdownSupport.titleFromFilename(target.url.lastPathComponent)
            text = MarkdownSupport.generateFrontmatter(title: title, tags: input.tags) + text
        }
        return PreparedFileWrite(
            data: Data(text.utf8),
            output: .text("Created \(target.relativePath)")
        )
    }

    /// Returns the complete UTF-8 Markdown document from a supplied snapshot.
    func read(
        _ request: ReadFileRequest,
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) throws -> FileOperationOutput {
        return .text(try TextFileSupport.string(from: snapshot.data))
    }

    /// Applies the requested Markdown update mode to a consistent file snapshot.
    func prepareUpdate(
        _ request: UpdateFileRequest,
        target: WritableFileTarget,
        snapshot: FileSnapshot
    ) throws -> PreparedFileWrite {
        let existing = try TextFileSupport.string(from: snapshot.data)
        let updated: String
        switch request.mode {
        case .replace:
            guard let content = request.content else { throw TextFileSupport.TextError.missingContent }
            updated = content
        case .append:
            guard let content = request.content else { throw TextFileSupport.TextError.missingContent }
            updated = TextFileSupport.appending(content, to: existing)
        case .patch:
            updated = try TextFileSupport.apply(request.replacements, to: existing)
        }
        return PreparedFileWrite(
            data: Data(updated.utf8),
            output: .text("Updated \(target.relativePath) (\(request.mode.rawValue))")
        )
    }
}
