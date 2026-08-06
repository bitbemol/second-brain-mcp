/// One exact text substitution used by Markdown patch updates.
struct TextReplacement: Sendable {
    /// Nonempty text that must occur exactly once in the original document.
    let oldText: String
    /// Replacement text; an empty value deletes the match.
    let newText: String
}

/// Transport-neutral input for a generic file update.
struct UpdateFileRequest: Sendable {
    /// Declared concrete storage format.
    let format: FileFormat
    /// Existing vault-relative path under `notes/`.
    let path: String
    /// Replacement or appended UTF-8 content.
    let content: String?
    /// Update strategy selected by the caller.
    let mode: FileUpdateMode
    /// Exact substitutions used when ``mode`` is ``FileUpdateMode/patch``.
    let replacements: [TextReplacement]
}
