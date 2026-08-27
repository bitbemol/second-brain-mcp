import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite("Recoverable deletion receipts")
struct DeletionReceiptTests {
    @Test("Deletion exposes the exact trash locator and deleted revision without granting trash access")
    func receiptIdentifiesRecoverableBytes() async throws {
        let fixture = try MediaImportBoundaryFixture()
        defer { fixture.cleanup() }
        let bytes = Data("recover these exact bytes\n".utf8)
        let path = "notes/recover.log"
        try bytes.write(to: fixture.vault.appendingPathComponent(path))
        let revision = FileSnapshot(data: bytes, modifiedDate: nil).revision.rawValue
        let controller = FileToolController(readOnly: false, files: fixture.service)
        let result = try await controller.call(.init(name: "delete_file", arguments: [
            "format": .string("log"), "path": .string(path), "expected_revision": .string(revision),
        ]))
        #expect(result.isError != true)
        let body = try #require(result.structuredContent?.objectValue)
        let trashPath = try #require(body["trash_path"]?.stringValue)
        #expect(trashPath.hasPrefix(".trash/"))
        #expect(!trashPath.contains(".."))
        #expect(body["deleted_revision"]?.stringValue == revision)
        #expect(!FileManager.default.fileExists(atPath: fixture.vault.appendingPathComponent(path).path))
        let trashBytes = try Data(contentsOf: fixture.vault.appendingPathComponent(trashPath))
        #expect(trashBytes == bytes)
        let summary = result.content.compactMap {
            if case .text(let text, _, _) = $0 { text } else { nil }
        }.joined()
        #expect(summary.contains(trashPath))
        #expect(summary.contains("manual"))
        #expect(summary.contains(revision))
        let blocked = try await controller.call(.init(name: "read_file", arguments: [
            "format": .string("log"), "path": .string(trashPath),
        ]))
        #expect(blocked.isError == true)

        // Models the documented user-controlled recovery without widening MCP authority.
        let restoredPath = "notes/restored.log"
        try FileManager.default.copyItem(at: fixture.vault.appendingPathComponent(trashPath),
                                         to: fixture.vault.appendingPathComponent(restoredPath))
        let restored = try await controller.call(.init(name: "read_file", arguments: [
            "format": .string("log"), "path": .string(restoredPath),
        ]))
        #expect(restored.isError != true)
        #expect(restored.structuredContent?.objectValue?["revision"]?.stringValue == revision)
        #expect(try Data(contentsOf: fixture.vault.appendingPathComponent(trashPath)) == bytes)
    }
}
