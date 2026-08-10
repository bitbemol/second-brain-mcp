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

    init(
        contents: [VaultFileContent],
        metadata: FileOperationMetadata? = nil
    ) {
        self.contents = contents
        self.metadata = metadata
    }

    static func text(_ text: String) -> FileOperationOutput {
        FileOperationOutput(contents: [.text(text)])
    }

    func withMetadata(_ metadata: FileOperationMetadata) -> FileOperationOutput {
        FileOperationOutput(contents: contents, metadata: metadata)
    }
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
