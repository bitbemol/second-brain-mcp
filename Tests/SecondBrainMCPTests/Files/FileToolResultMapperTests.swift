import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct `MCP file result mapper` {
    @Test
    func `Content and structured operation metadata preserve their wire shapes`() throws {
        let revision = try #require(FileRevision(
            rawValue: "sha256:" + String(repeating: "a", count: 64)
        ))
        let result = FileToolResultMapper.success(FileOperationOutput(
            contents: [
                .text("summary"),
                .image(data: Data([0x47, 0x49, 0x46]), mimeType: "image/gif"),
            ],
            metadata: FileOperationMetadata(
                path: "notes/demo.gif",
                area: .notes,
                revision: revision
            )
        ))

        #expect(result.isError != true)
        #expect(result.content.count == 3)
        guard case .text(let text, _, _) = result.content[0],
              case .image(let data, let mimeType, _, _) = result.content[1] else {
            Issue.record("Expected ordered text and image content")
            return
        }
        #expect(text == "summary")
        #expect(data == "R0lG")
        #expect(mimeType == "image/gif")

        let metadata = try #require(result.structuredContent?.objectValue)
        #expect(Set(metadata.keys) == ["path", "area", "revision"])
        #expect(metadata["path"]?.stringValue == "notes/demo.gif")
        #expect(metadata["area"]?.stringValue == "notes")
        #expect(metadata["revision"]?.stringValue == revision.rawValue)
    }

    @Test
    func `Revision metadata is mirrored into ordinary content`() throws {
        let revision = try #require(FileRevision(
            rawValue: "sha256:" + String(repeating: "b", count: 64)
        ))
        let result = FileToolResultMapper.success(FileOperationOutput(
            contents: [.text("stored content")],
            metadata: FileOperationMetadata(
                path: "notes/demo.md",
                area: .notes,
                revision: revision
            )
        ))

        #expect(result.content.count == 2)
        guard case .text(let metadataText, _, _) = result.content.last else {
            Issue.record("Expected a trailing metadata text block")
            return
        }
        let data = try #require(metadataText.data(using: .utf8))
        let metadata = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        #expect(metadata == [
            "path": "notes/demo.md",
            "area": "notes",
            "revision": revision.rawValue,
        ])
    }

    @Test
    func `Text pagination metadata is exposed in structured and ordinary content`() throws {
        let revision = try #require(FileRevision(
            rawValue: "sha256:" + String(repeating: "c", count: 64)
        ))
        let result = FileToolResultMapper.success(FileOperationOutput(
            contents: [.text("chunk")],
            metadata: FileOperationMetadata(
                path: "notes/large.md",
                area: .notes,
                revision: revision
            ),
            textWindow: TextReadWindow(
                byteOffset: 65_536,
                byteCount: 5,
                totalBytes: 70_000,
                nextByteOffset: 65_541
            )
        ))

        let structured = try #require(result.structuredContent?.objectValue)
        let window = try #require(structured["text_window"]?.objectValue)
        #expect(window["byte_offset"]?.intValue == 65_536)
        #expect(window["byte_count"]?.intValue == 5)
        #expect(window["total_bytes"]?.intValue == 70_000)
        #expect(window["next_byte_offset"]?.intValue == 65_541)

        guard case .text(let metadataText, _, _) = result.content.last else {
            Issue.record("Expected trailing metadata")
            return
        }
        let data = try #require(metadataText.data(using: .utf8))
        let metadata = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let ordinaryWindow = try #require(
            metadata["text_window"] as? [String: Int]
        )
        #expect(ordinaryWindow["next_byte_offset"] == 65_541)
    }

    @Test
    func `Content-free read metadata is emitted as structured and ordinary JSON`() throws {
        let output = FileOperationOutput(
            contents: [],
            metadata: FileOperationMetadata(
                path: "notes/map.md",
                area: .notes,
                revision: FileSnapshot(
                    data: Data("map".utf8),
                    modifiedDate: nil
                ).revision
            ),
            readMetadata: FileReadMetadata(
                format: .markdown,
                byteCount: 3,
                modifiedAt: nil,
                title: "Map",
                tags: ["agent"],
                wordCount: 1,
                outgoingLinkTargets: ["next.md"],
                author: nil,
                pageCount: nil,
                pageLabels: nil,
                pageLabelsTruncated: nil,
                outline: nil,
                outlineTruncated: nil
            )
        )

        let result = FileToolResultMapper.success(output)
        let structured = try #require(result.structuredContent?.objectValue)
        let metadata = try #require(structured["metadata"]?.objectValue)
        #expect(metadata["format"]?.stringValue == "markdown")
        #expect(metadata["byte_count"]?.intValue == 3)
        #expect(metadata["title"]?.stringValue == "Map")
        #expect(metadata["outgoing_link_targets"]?.arrayValue?.first?.stringValue
            == "next.md")
        guard case .text(let metadataText, _, _) = result.content.first else {
            Issue.record("Expected metadata JSON content")
            return
        }
        let data = try #require(metadataText.data(using: .utf8))
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["byte_count"] as? Int == 3)
        #expect(json["title"] as? String == "Map")
    }

    @Test
    func `Absent operation metadata does not invent structured content`() {
        let result = FileToolResultMapper.success(.text("plain"))
        #expect(result.structuredContent == nil)
    }

    @Test
    func `Failure results contain one diagnostic block`() {
        let result = FileToolResultMapper.failure("broken")

        #expect(result.isError == true)
        #expect(result.content.count == 1)
    }
}
