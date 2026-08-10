import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Audit rejection reporter` {
    @Test
    func `Transport rejection is translated into backend audit vocabulary`() async throws {
        let root = NSTemporaryDirectory() + "AuditRejectionReporterTests-\(UUID().uuidString)"
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let reporter = AuditRejectionReporter(
            audit: AuditLogger(dataDirectory: dataDirectory)
        )

        await reporter.record(FileRequestRejection(
            operation: .update,
            path: "notes/blocked.md",
            reason: .readOnly
        ))
        await reporter.record(FileRequestRejection(
            operation: .move,
            path: "notes/in-progress/ticket-123",
            reason: .readOnly
        ))

        let contents = try String(
            contentsOf: dataDirectory.auditLogURL,
            encoding: .utf8
        )
        #expect(contents.contains("UPDATE"))
        #expect(contents.contains("notes/blocked.md"))
        #expect(contents.contains("update_file rejected: read-only"))
        #expect(contents.contains("MOVE"))
        #expect(contents.contains("move_directory rejected: read-only"))
    }
}
