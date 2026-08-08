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
        return CallTool.Result(
            content: content,
            structuredContent: output.metadata.map(structuredContent)
        )
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

    /// Converts transport-neutral operation metadata to its stable MCP shape.
    private static func structuredContent(
        _ metadata: FileOperationMetadata
    ) -> Value {
        var values: [String: Value] = [
            FileToolOutputField.path.rawValue: .string(metadata.path),
            FileToolOutputField.area.rawValue: .string(metadata.area.rawValue),
            FileToolOutputField.replayed.rawValue: .bool(metadata.replayed),
        ]
        if let sourcePath = metadata.sourcePath {
            values[FileToolOutputField.sourcePath] = .string(sourcePath)
            values[FileToolOutputField.destinationPath] = .string(metadata.path)
        }
        if let revision = metadata.revision {
            values[FileToolOutputField.revision] = .string(revision.rawValue)
        }
        if let mutationID = metadata.mutationID {
            values[FileToolOutputField.mutationID] = .string(mutationID.rawValue)
        }
        return .object(values)
    }
}
