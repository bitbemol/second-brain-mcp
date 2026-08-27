import Foundation
import MCP

/// Maps transport-neutral operation outputs and errors into MCP tool results.
enum FileToolResultMapper {
    /// Converts ordered text and image blocks into a successful file-tool result.
    static func success(_ output: FileOperationOutput) -> CallTool.Result {
        var content = content(from: output)
        if let readMetadata = output.readMetadata,
           let text = readMetadataText(readMetadata) {
            content.append(.text(text: text, annotations: nil, _meta: nil))
        }
        if output.metadata?.revision != nil,
           let text = metadataText(output) {
            content.append(.text(text: text, annotations: nil, _meta: nil))
        }
        return CallTool.Result(
            content: content,
            structuredContent: output.metadata.map { _ in
                fileStructuredContent(output)
            }
        )
    }

    /// Converts a file or directory move into its compact structural result.
    static func pathMoveSuccess(_ output: FileOperationOutput) -> CallTool.Result {
        guard let metadata = output.metadata,
              let sourcePath = metadata.sourcePath else {
            return failure("Path move completed without required result metadata")
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
        ToolErrorResponse.failure(message)
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
    private static func metadataText(_ output: FileOperationOutput) -> String? {
        guard let metadata = output.metadata,
              let revision = metadata.revision else { return nil }
        var values: [String: Any] = [
            FileToolOutputField.path.rawValue: metadata.path,
            FileToolOutputField.area.rawValue: metadata.area.rawValue,
            FileToolOutputField.revision.rawValue: revision.rawValue,
        ]
        if let window = output.textWindow {
            values[FileToolOutputField.textWindow.rawValue] = textWindowJSON(window)
        }
        if let selection = output.canvasSelection {
            values[FileToolOutputField.canvasNodeID.rawValue] = selection.nodeID
            values[FileToolOutputField.canvasField.rawValue] = selection.field.rawValue
        }
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
        _ output: FileOperationOutput
    ) -> Value {
        guard let metadata = output.metadata else { return .object([:]) }
        var values: [String: Value] = [
            FileToolOutputField.path.rawValue: .string(metadata.path),
            FileToolOutputField.area.rawValue: .string(metadata.area.rawValue),
        ]
        if let revision = metadata.revision {
            values[FileToolOutputField.revision] = .string(revision.rawValue)
        }
        if let readMetadata = output.readMetadata {
            values[FileToolOutputField.readMetadata] = readMetadataValue(readMetadata)
        }
        if let selection = output.canvasSelection {
            values[FileToolOutputField.canvasNodeID] = .string(selection.nodeID)
            values[FileToolOutputField.canvasField] = .string(selection.field.rawValue)
        }
        if let window = output.textWindow {
            var windowValues: [String: Value] = [
                FileToolOutputField.byteOffset.rawValue: .int(window.byteOffset),
                FileToolOutputField.byteCount.rawValue: .int(window.byteCount),
                FileToolOutputField.totalBytes.rawValue: .int(window.totalBytes),
            ]
            if let next = window.nextByteOffset {
                windowValues[FileToolOutputField.nextByteOffset.rawValue] = .int(next)
            }
            values[FileToolOutputField.textWindow] = .object(windowValues)
        }
        return .object(values)
    }

    private static func readMetadataText(_ metadata: FileReadMetadata) -> String? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(metadata) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func readMetadataValue(_ metadata: FileReadMetadata) -> Value {
        var values: [String: Value] = [
            "format": .string(metadata.format.rawValue),
            "byte_count": .int(metadata.byteCount),
            "incomplete_fields": .array(metadata.incompleteFields.map { .string($0.rawValue) }),
        ]
        if let value = metadata.modifiedAt { values["modified_at"] = .string(value) }
        if let value = metadata.title { values["title"] = .string(value) }
        if let value = metadata.tags { values["tags"] = .array(value.map(Value.string)) }
        if let value = metadata.wordCount { values["word_count"] = .int(value) }
        if let value = metadata.outgoingLinkTargets {
            values["outgoing_link_targets"] = .array(value.map(Value.string))
        }
        if let value = metadata.author { values["author"] = .string(value) }
        if let value = metadata.pageCount { values["page_count"] = .int(value) }
        if let value = metadata.pageLabels {
            values["page_labels"] = .array(value.map(Value.string))
        }
        if let value = metadata.pageLabelsTruncated {
            values["page_labels_truncated"] = .bool(value)
        }
        if let outline = metadata.outline {
            values["outline"] = .array(outline.map { entry in
                var item: [String: Value] = [
                    "label": .string(entry.label),
                    "depth": .int(entry.depth),
                ]
                if let page = entry.page { item["page"] = .int(page) }
                return .object(item)
            })
        }
        if let value = metadata.outlineTruncated {
            values["outline_truncated"] = .bool(value)
        }
        return .object(values)
    }

    private static func textWindowJSON(
        _ window: TextReadWindow
    ) -> [String: Int] {
        var values = [
            FileToolOutputField.byteOffset.rawValue: window.byteOffset,
            FileToolOutputField.byteCount.rawValue: window.byteCount,
            FileToolOutputField.totalBytes.rawValue: window.totalBytes,
        ]
        if let next = window.nextByteOffset {
            values[FileToolOutputField.nextByteOffset.rawValue] = next
        }
        return values
    }
}
