import Foundation
import MCP

/// Maps transport-neutral operation outputs and errors into MCP tool results.
enum FileToolResultMapper {
    /// Converts ordered text and image blocks into a successful file-tool result.
    static func success(_ output: FileOperationOutput) -> CallTool.Result {
        CallTool.Result(
            content: content(from: output),
            structuredContent: output.metadata.map(fileStructuredContent)
        )
    }

    /// Converts a directory move into its compact structural result.
    static func directoryMoveSuccess(_ output: FileOperationOutput) -> CallTool.Result {
        guard let metadata = output.metadata,
              let sourcePath = metadata.sourcePath,
              let mutationID = metadata.mutationID else {
            return failure("Directory move completed without required result metadata")
        }
        return CallTool.Result(
            content: content(from: output),
            structuredContent: .object([
                FileToolOutputField.sourcePath.rawValue: .string(sourcePath),
                FileToolOutputField.destinationPath.rawValue: .string(metadata.path),
                FileToolOutputField.mutationID.rawValue: .string(mutationID.rawValue),
                FileToolOutputField.replayed.rawValue: .bool(metadata.replayed),
            ])
        )
    }

    /// Creates a failed MCP result containing one diagnostic text block.
    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private static func content(
        from output: FileOperationOutput
    ) -> [Tool.Content] {
        output.contents.map { item in
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
    }

    /// Converts transport-neutral file metadata to its stable MCP shape.
    private static func fileStructuredContent(
        _ metadata: FileOperationMetadata
    ) -> Value {
        var values: [String: Value] = [
            FileToolOutputField.path.rawValue: .string(metadata.path),
            FileToolOutputField.area.rawValue: .string(metadata.area.rawValue),
            FileToolOutputField.replayed.rawValue: .bool(metadata.replayed),
        ]
        if let revision = metadata.revision {
            values[FileToolOutputField.revision] = .string(revision.rawValue)
        }
        if let mutationID = metadata.mutationID {
            values[FileToolOutputField.mutationID] = .string(mutationID.rawValue)
        }
        return .object(values)
    }
}
