/// Format-specific options accepted by a generic file read.
struct ReadFileOptions: Sendable {
    /// Number of trailing log lines to return.
    let tailLines: Int?
    /// First one-indexed log line in a bounded range.
    let startLine: Int?
    /// Maximum log lines returned from startLine.
    let maxLines: Int?
    /// One physical one-indexed PDF page.
    let page: Int?
    /// Ordered physical one-indexed PDF pages.
    let pages: [Int]?
    /// Inclusive physical PDF range formatted as start-end.
    let pageRange: String?

    /// Options representing each format's default read behavior.
    init(
        tailLines: Int? = nil,
        startLine: Int? = nil,
        maxLines: Int? = nil,
        page: Int? = nil,
        pages: [Int]? = nil,
        pageRange: String? = nil
    ) {
        self.tailLines = tailLines
        self.startLine = startLine
        self.maxLines = maxLines
        self.page = page
        self.pages = pages
        self.pageRange = pageRange
    }

    static let `default` = ReadFileOptions()
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
