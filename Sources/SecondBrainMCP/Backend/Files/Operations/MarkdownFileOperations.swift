import Foundation

/// Adds Markdown front matter during creation when the caller did not provide it.
struct MarkdownFileOperations: Sendable {
    func prepareCreate(
        _ input: TextFileCreateInput,
        target: WritableFileTarget
    ) throws -> PreparedFileWrite {
        var text = try TextFileSupport.string(from: input.data)
        if !MarkdownSupport.hasFrontmatter(text) {
            let title = MarkdownSupport.titleFromFilename(
                target.url.lastPathComponent
            )
            text = MarkdownSupport.generateFrontmatter(
                title: title,
                tags: input.tags
            ) + text
        }
        return PreparedFileWrite(
            data: Data(text.utf8),
            output: .text("Created \(target.relativePath)")
        )
    }
}
