/// Format-specific options accepted by a generic file read.
struct ReadFileOptions: Sendable {
    /// Number of trailing log lines to return.
    let tailLines: Int?
    /// First one-indexed log line in a bounded range.
    let startLine: Int?
    /// Maximum log lines returned from startLine.
    let maxLines: Int?
    /// Physical one-indexed PDF page.
    let page: Int?
    /// Printed PDF page label, such as xii or 42.
    let bookPage: String?
    /// Inclusive physical PDF range formatted as start-end.
    let pageRange: String?
    /// Maximum number of rendered PDF pages.
    let maxPages: Int?

    /// Options representing each format's default read behavior.
    static let `default` = ReadFileOptions(
        tailLines: nil,
        startLine: nil,
        maxLines: nil,
        page: nil,
        bookPage: nil,
        pageRange: nil,
        maxPages: nil
    )
}

/// Transport-neutral input for a generic file read.
struct ReadFileRequest: Sendable {
    /// Declared concrete storage format.
    let format: FileFormat
    /// Vault-relative source path.
    let path: String
    /// Optional format-specific rendering controls.
    let options: ReadFileOptions
}
