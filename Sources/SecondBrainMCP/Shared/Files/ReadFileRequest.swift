/// Agent-facing representation requested from one supported file.
enum ReadFileView: String, CaseIterable, Codable, Sendable {
    /// Return bounded file content using the format's normal read behavior.
    case content
    /// Return bounded structured metadata without content, page text, or images.
    case metadata
}

/// Format-specific options accepted by a generic file read.
struct ReadFileOptions: Sendable {
    /// Explicit content or metadata representation.
    let view: ReadFileView
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
    /// Zero-based UTF-8 byte offset for a stored-text chunk.
    let byteOffset: Int?
    /// Maximum UTF-8 bytes returned for a stored-text chunk.
    let maxBytes: Int?
    /// Exact-byte revision that a continuation expects to read.
    let expectedRevision: FileRevision?

    /// Options representing each format's default read behavior.
    init(
        view: ReadFileView = .content,
        tailLines: Int? = nil,
        startLine: Int? = nil,
        maxLines: Int? = nil,
        page: Int? = nil,
        pages: [Int]? = nil,
        pageRange: String? = nil,
        byteOffset: Int? = nil,
        maxBytes: Int? = nil,
        expectedRevision: FileRevision? = nil
    ) {
        self.view = view
        self.tailLines = tailLines
        self.startLine = startLine
        self.maxLines = maxLines
        self.page = page
        self.pages = pages
        self.pageRange = pageRange
        self.byteOffset = byteOffset
        self.maxBytes = maxBytes
        self.expectedRevision = expectedRevision
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

/// One bounded flattened PDF outline entry.
struct PDFOutlineMetadataEntry: Equatable, Sendable, Codable {
    /// Human-readable PDF outline label, truncated to the metadata string ceiling.
    let label: String
    /// One-based physical destination page, when the PDF exposes one.
    let page: Int?
    /// Zero-based nesting depth retained by the bounded traversal.
    let depth: Int
}

/// Content-free facts returned by read_file with view metadata.
struct FileReadMetadata: Equatable, Sendable, Codable {
    let format: FileFormat
    let byteCount: Int
    let modifiedAt: String?
    let title: String?
    let tags: [String]?
    let wordCount: Int?
    let outgoingLinkTargets: [String]?
    let author: String?
    let pageCount: Int?
    let pageLabels: [String]?
    let pageLabelsTruncated: Bool?
    let outline: [PDFOutlineMetadataEntry]?
    let outlineTruncated: Bool?
}

/// Public response ceilings for content-free metadata.
enum FileMetadataLimits {
    static let maximumStringBytes = 1_024
    static let maximumTags = 256
    static let maximumOutgoingLinks = 512
    static let maximumOutgoingLinkBytes = 64 * 1_024
    static let maximumPDFPageLabels = 512
    static let maximumPDFOutlineEntries = 256
    static let maximumPDFOutlineDepth = 8
}
