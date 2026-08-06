import Foundation
import MCP

/// Maps transport-neutral file outputs and errors into MCP tool results.
enum FileToolResultMapper {
    /// Converts ordered text and image blocks into MCP content.
    ///
    /// - Parameter output: Completed transport-neutral file output.
    /// - Returns: Successful MCP tool result.
    static func success(_ output: FileOperationOutput) -> CallTool.Result {
        let content: [Tool.Content] = output.contents.map { item in
            switch item {
            case .text(let text):
                .text(text: text, annotations: nil, _meta: nil)
            case .image(let data, let mimeType):
                .image(
                    data: data.base64EncodedString(),
                    mimeType: mimeType,
                    annotations: nil,
                    _meta: nil
                )
            }
        }
        return CallTool.Result(content: content)
    }

    /// Creates a failed MCP result containing one diagnostic text block.
    ///
    /// - Parameter message: User-facing failure description.
    /// - Returns: Failed MCP tool result.
    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}
