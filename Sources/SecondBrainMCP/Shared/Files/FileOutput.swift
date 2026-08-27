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
    /// Selected decoded Canvas field, absent for ordinary raw-file reads.
    let canvasSelection: CanvasReadSelection?

    init(
        contents: [VaultFileContent],
        metadata: FileOperationMetadata? = nil,
        textWindow: TextReadWindow? = nil,
        readMetadata: FileReadMetadata? = nil,
        canvasSelection: CanvasReadSelection? = nil
    ) {
        self.contents = contents
        self.metadata = metadata
        self.textWindow = textWindow
        self.readMetadata = readMetadata
        self.canvasSelection = canvasSelection
    }

    static func text(
        _ text: String,
        textWindow: TextReadWindow? = nil,
        canvasSelection: CanvasReadSelection? = nil
    ) -> FileOperationOutput {
        FileOperationOutput(
            contents: [.text(text)],
            textWindow: textWindow,
            canvasSelection: canvasSelection
        )
    }

    static func metadata(_ metadata: FileReadMetadata) -> FileOperationOutput {
        FileOperationOutput(contents: [], readMetadata: metadata)
    }

    func withMetadata(_ metadata: FileOperationMetadata) -> FileOperationOutput {
        FileOperationOutput(
            contents: contents,
            metadata: metadata,
            textWindow: textWindow,
            readMetadata: readMetadata,
            canvasSelection: canvasSelection
        )
    }
}

/// Externally observable UTF-8 byte window returned by a paginated text read.
struct TextReadWindow: Sendable, Codable, Equatable {
    /// Zero-based offset of the returned bytes.
    let byteOffset: Int
    /// Number of UTF-8 bytes returned.
    let byteCount: Int
    /// Total UTF-8 bytes in the selected representation (raw file or Canvas field).
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
    /// Exact recoverable trash locator, present only after a successful deletion.
    let trashPath: String?
    /// Revision of the retained deleted bytes, not an active notes revision.
    let deletedRevision: FileRevision?

    init(
        path: String,
        sourcePath: String? = nil,
        area: VaultArea,
        revision: FileRevision?,
        trashPath: String? = nil,
        deletedRevision: FileRevision? = nil
    ) {
        self.path = path
        self.sourcePath = sourcePath
        self.area = area
        self.revision = revision
        self.trashPath = trashPath
        self.deletedRevision = deletedRevision
    }
}
