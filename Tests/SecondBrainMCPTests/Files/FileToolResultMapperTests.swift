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
        #expect(result.content.count == 2)
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
