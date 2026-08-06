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

    /// Creates an operation output with optional structured metadata.
    init(
        contents: [VaultFileContent],
        metadata: FileOperationMetadata? = nil
    ) {
        self.contents = contents
        self.metadata = metadata
    }

    /// Creates an output containing one text block.
    ///
    /// - Parameter text: Text returned to the MCP client.
    /// - Returns: A single-block operation output.
    static func text(_ text: String) -> FileOperationOutput {
        FileOperationOutput(contents: [.text(text)])
    }

    /// Returns the same content associated with authoritative file metadata.
    func withMetadata(_ metadata: FileOperationMetadata) -> FileOperationOutput {
        FileOperationOutput(contents: contents, metadata: metadata)
    }
}

/// Structured facts returned alongside human-readable operation content.
struct FileOperationMetadata: Sendable, Codable {
    /// Canonical vault-relative path operated on.
    let path: String
    /// Structural vault area containing the path.
    let area: VaultArea
    /// Exact stored-byte revision, when a file remains after the operation.
    let revision: FileRevision?
    /// Mutation identity for create, update, and delete results.
    let mutationID: MutationID?
    /// Whether this result was restored from a durable idempotency receipt.
    let replayed: Bool

    /// Returns a copy marked as a replay of an earlier completed mutation.
    func markingReplayed() -> FileOperationMetadata {
        FileOperationMetadata(
            path: path,
            area: area,
            revision: revision,
            mutationID: mutationID,
            replayed: true
        )
    }
}
