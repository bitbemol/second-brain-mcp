import Foundation
import MCP
import Testing
@testable import SecondBrainMCP

@Suite("MCP file result mapper")
struct FileToolResultMapperTests {
    @Test("Text and image outputs preserve order and encoding")
    func successfulOutput() throws {
        let result = FileToolResultMapper.success(FileOperationOutput(contents: [
            .text("summary"),
            .image(data: Data([0x47, 0x49, 0x46]), mimeType: "image/gif"),
        ]))

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
    }

    @Test("Failure results contain one diagnostic block")
    func failedOutput() {
        let result = FileToolResultMapper.failure("broken")

        #expect(result.isError == true)
        #expect(result.content.count == 1)
    }
}
