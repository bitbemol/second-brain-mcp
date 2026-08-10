import Testing
@testable import second_brain_mcp

@Suite("Audit log entry")
struct AuditLogEntryTests {
    @Test("Escapes record and field delimiters in untrusted values")
    func escapesUntrustedFields() {
        let entry = AuditLogEntry(
            timestamp: "2026-08-06T12:00:00Z",
            operation: .delete,
            area: .notes,
            path: "notes/real.md\n2099-01-01 | DELETE | forged",
            details: "reason\r\nwith | delimiter \\ marker\t\u{2028}next"
        ).line

        #expect(entry.filter { $0 == "\n" }.count == 1)
        #expect(entry.hasSuffix("\n"))
        #expect(entry.contains(
            "notes/real.md\\n2099-01-01 \\| DELETE \\| forged"
        ))
        #expect(entry.contains(
            "reason\\r\\nwith \\| delimiter \\\\ marker\\t\\nnext"
        ))
    }

    @Test("Reference reads retain their stored audit vocabulary")
    func preservesReferenceReadOperation() {
        let entry = AuditLogEntry(
            timestamp: "2026-08-06T12:00:00Z",
            operation: .read,
            area: .references,
            path: "references/manual.pdf",
            details: "pdf"
        ).line

        #expect(entry.contains("READ_REF"))
    }

    @Test("Directory moves have a distinct stable audit operation")
    func moveOperation() {
        let entry = AuditLogEntry(
            timestamp: "2026-08-06T12:00:00Z",
            operation: .move,
            area: .notes,
            path: "notes/in-progress/ticket-123",
            details: "destination=notes/completed/ticket-123"
        ).line

        #expect(entry.contains("MOVE"))
        #expect(entry.contains("notes/completed/ticket-123"))
    }

    @Test("Bounds caller-controlled fields")
    func boundsFields() {
        let entry = AuditLogEntry(
            timestamp: "2026-08-06T12:00:00Z",
            operation: .read,
            area: .notes,
            path: String(repeating: "x", count: 10_000),
            details: nil
        ).line

        #expect(entry.contains("…"))
        #expect(entry.utf8.count < 3_000)
    }
}
