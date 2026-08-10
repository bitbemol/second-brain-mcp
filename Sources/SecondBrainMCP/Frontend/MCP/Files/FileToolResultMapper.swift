import Foundation
import MCP

/// Maps transport-neutral operation outputs and errors into MCP tool results.
enum FileToolResultMapper {
    /// Converts ordered text and image blocks into a successful file-tool result.
    static func success(_ output: FileOperationOutput) -> CallTool.Result {
        var content = content(from: output)
        if let metadata = output.metadata,
           metadata.revision != nil,
           let text = metadataText(metadata) {
            content.append(.text(text: text, annotations: nil, _meta: nil))
        }
        return CallTool.Result(
            content: content,
            structuredContent: output.metadata.map(fileStructuredContent)
        )
    }

    /// Converts a directory move into its compact structural result.
    static func directoryMoveSuccess(_ output: FileOperationOutput) -> CallTool.Result {
        guard let metadata = output.metadata,
              let sourcePath = metadata.sourcePath else {
            return failure("Directory move completed without required result metadata")
        }
        return CallTool.Result(
            content: content(from: output),
            structuredContent: .object([
                FileToolOutputField.sourcePath.rawValue: .string(sourcePath),
                FileToolOutputField.destinationPath.rawValue: .string(metadata.path),
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

    /// Mirrors revision-bearing metadata for clients that expose only content blocks.
    private static func metadataText(_ metadata: FileOperationMetadata) -> String? {
        guard let revision = metadata.revision else { return nil }
        let values = [
            FileToolOutputField.path.rawValue: metadata.path,
            FileToolOutputField.area.rawValue: metadata.area.rawValue,
            FileToolOutputField.revision.rawValue: revision.rawValue,
        ]
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(
                  withJSONObject: values,
                  options: [.sortedKeys]
              ) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Converts transport-neutral file metadata to its stable MCP shape.
    private static func fileStructuredContent(
        _ metadata: FileOperationMetadata
    ) -> Value {
        var values: [String: Value] = [
            FileToolOutputField.path.rawValue: .string(metadata.path),
            FileToolOutputField.area.rawValue: .string(metadata.area.rawValue),
        ]
        if let revision = metadata.revision {
            values[FileToolOutputField.revision] = .string(revision.rawValue)
        }
        return .object(values)
    }
}
