import Foundation

/// A transport-neutral content block produced by a file operation.
enum VaultFileContent: Sendable, Codable {
    /// UTF-8 text suitable for an MCP text content block.
    case text(String)
    /// Encoded image bytes and their Internet media type.
    case image(data: Data, mimeType: String)
}

/// Ordered content blocks returned by a completed file operation.
struct FileOperationOutput: Sendable, Codable {
    /// Text and image blocks in presentation order.
    let contents: [VaultFileContent]
    /// Stable identity and path facts associated with the completed operation.
    let metadata: FileOperationMetadata?
    /// Explicit byte window for a paginated UTF-8 text response.
    let textWindow: TextReadWindow?
    /// Content-free format metadata for an explicit metadata read.
    let readMetadata: FileReadMetadata?

    init(
        contents: [VaultFileContent],
        metadata: FileOperationMetadata? = nil,
        textWindow: TextReadWindow? = nil,
        readMetadata: FileReadMetadata? = nil
    ) {
        self.contents = contents
        self.metadata = metadata
        self.textWindow = textWindow
        self.readMetadata = readMetadata
    }

    static func text(
        _ text: String,
        textWindow: TextReadWindow? = nil
    ) -> FileOperationOutput {
        FileOperationOutput(contents: [.text(text)], textWindow: textWindow)
    }

    static func metadata(_ metadata: FileReadMetadata) -> FileOperationOutput {
        FileOperationOutput(contents: [], readMetadata: metadata)
    }

    func withMetadata(_ metadata: FileOperationMetadata) -> FileOperationOutput {
        FileOperationOutput(
            contents: contents,
            metadata: metadata,
            textWindow: textWindow,
            readMetadata: readMetadata
        )
    }
}

/// Externally observable UTF-8 byte window returned by a paginated text read.
struct TextReadWindow: Sendable, Codable, Equatable {
    /// Zero-based offset of the returned bytes.
    let byteOffset: Int
    /// Number of UTF-8 bytes returned.
    let byteCount: Int
    /// Complete validated document size in UTF-8 bytes.
    let totalBytes: Int
    /// Offset for the next chunk, or nil when this chunk completes the document.
    let nextByteOffset: Int?
}

/// Structured facts returned alongside human-readable operation content.
struct FileOperationMetadata: Sendable, Codable {
    /// Canonical vault-relative path operated on.
    let path: String
    /// Original path for a move operation, when one path became another.
    let sourcePath: String?
    /// Structural vault area containing the path.
    let area: VaultArea
    /// Exact stored-byte revision, when a file remains after the operation.
    let revision: FileRevision?

    init(
        path: String,
        sourcePath: String? = nil,
        area: VaultArea,
        revision: FileRevision?
    ) {
        self.path = path
        self.sourcePath = sourcePath
        self.area = area
        self.revision = revision
    }
}
