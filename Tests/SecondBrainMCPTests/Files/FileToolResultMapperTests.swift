import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite("MCP file result mapper")
struct FileToolResultMapperTests {
    @Test("Content and structured operation metadata preserve their wire shapes")
    func successfulOutput() throws {
        let revision = try #require(FileRevision(
            rawValue: "sha256:" + String(repeating: "a", count: 64)
        ))
        let mutationID = try #require(MutationID(
            rawValue: "e7dc1f3a-5a20-41e9-91d8-3b9d289787b0"
        ))
        let result = FileToolResultMapper.success(FileOperationOutput(
            contents: [
                .text("summary"),
                .image(data: Data([0x47, 0x49, 0x46]), mimeType: "image/gif"),
            ],
            metadata: FileOperationMetadata(
                path: "notes/demo.gif",
                area: .notes,
                revision: revision,
                mutationID: mutationID,
                replayed: true
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
        #expect(metadata["path"]?.stringValue == "notes/demo.gif")
        #expect(metadata["area"]?.stringValue == "notes")
        #expect(metadata["revision"]?.stringValue == revision.rawValue)
        #expect(metadata["mutation_id"]?.stringValue == mutationID.rawValue)
        #expect(metadata["replayed"]?.boolValue == true)
    }

    @Test("Absent operation metadata does not invent structured content")
    func noMetadata() {
        let result = FileToolResultMapper.success(.text("plain"))
        #expect(result.structuredContent == nil)
    }

    @Test("Failure results contain one diagnostic block")
    func failedOutput() {
        let result = FileToolResultMapper.failure("broken")

        #expect(result.isError == true)
        #expect(result.content.count == 1)
    }
}
