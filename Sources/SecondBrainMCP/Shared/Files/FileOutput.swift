import Foundation

/// A transport-neutral content block produced by a file operation.
enum VaultFileContent: Sendable {
    /// UTF-8 text suitable for an MCP text content block.
    case text(String)
    /// Encoded image bytes and their Internet media type.
    case image(data: Data, mimeType: String)
}

/// Ordered content blocks returned by a completed file operation.
struct FileOperationOutput: Sendable {
    /// Text and image blocks in presentation order.
    let contents: [VaultFileContent]

    /// Creates an output containing one text block.
    ///
    /// - Parameter text: Text returned to the MCP client.
    /// - Returns: A single-block operation output.
    static func text(_ text: String) -> FileOperationOutput {
        FileOperationOutput(contents: [.text(text)])
    }
}
