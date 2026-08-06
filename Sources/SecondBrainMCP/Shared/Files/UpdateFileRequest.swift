/// One exact text substitution used by Markdown patch updates.
struct TextReplacement: Sendable, Codable {
    /// Nonempty text that must occur exactly once in the original document.
    let oldText: String
    /// Replacement text; an empty value deletes the match.
    let newText: String
}

/// Transport-neutral input for a generic file update.
struct UpdateFileRequest: Sendable, Codable {
    /// Caller-generated identity used to replay a timed-out mutation safely.
    let mutationID: MutationID
    /// Revision returned by the read on which this update is based.
    let expectedRevision: FileRevision
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
