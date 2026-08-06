/// Transport-neutral input for a generic file creation.
struct CreateFileRequest: Sendable {
    /// Declared concrete storage format.
    let format: FileFormat
    /// Vault-relative destination under `notes/`.
    let path: String
    /// Inline UTF-8 input for text and structured formats.
    let content: String?
    /// External regular-file path for supported media imports.
    let source: String?
    /// Markdown tags used when generated frontmatter is required.
    let tags: [String]
    /// Optional explicit media transformation.
    let transform: FileCreateTransform?
}
