import Testing
@testable import SecondBrainMCP

@Suite("AuditLogger.Operation")
struct AuditLoggerOperationTests {

    @Test("isWrite classifies mutating operations")
    func writeOps() {
        for op in [AuditLogger.Operation.create, .update, .delete, .move] {
            #expect(op.isWrite, "\(op.rawValue) should be a write")
        }
    }

    @Test("isWrite classifies read operations as non-writes")
    func readOps() {
        for op in [AuditLogger.Operation.read, .search, .readRef, .searchRef, .listRef, .metadataRef] {
            #expect(!op.isWrite, "\(op.rawValue) should not be a write")
        }
    }
}
