import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Audit rejection reporter")
struct AuditRejectionReporterTests {
    @Test("Transport rejection is translated into backend audit vocabulary")
    func recordsRejection() async throws {
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

        let contents = try String(
            contentsOf: dataDirectory.auditLogURL,
            encoding: .utf8
        )
        #expect(contents.contains("UPDATE"))
        #expect(contents.contains("notes/blocked.md"))
        #expect(contents.contains("update_file rejected: read-only"))
    }
}
