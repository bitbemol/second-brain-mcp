import Foundation
import Testing
@testable import second_brain_mcp

@Suite("Audit logger")
struct AuditLoggerTests {
    @Test("Reference reads retain their distinct stored operation")
    func referenceRead() async throws {
        let root = NSTemporaryDirectory() + "AuditLoggerTests-\(UUID().uuidString)"
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let audit = AuditLogger(dataDirectory: dataDirectory)

        await audit.log(
            operation: .read,
            area: .references,
            path: "references/manual.pdf",
            details: "pdf"
        )

        let contents = try String(
            contentsOf: dataDirectory.auditLogURL,
            encoding: .utf8
        )
        #expect(contents.contains("READ_REF"))
        #expect(contents.contains("references/manual.pdf"))
    }

    @Test("Rotates the audit log at a fixed size")
    func rotatesBySize() async throws {
        let root = NSTemporaryDirectory() + "AuditLoggerTests-\(UUID().uuidString)"
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let audit = AuditLogger(
            dataDirectory: dataDirectory,
            maximumBytes: 256,
            retainedFiles: 2
        )

        for index in 0..<20 {
            await audit.log(
                operation: .read,
                path: "notes/entry-\(index).md",
                details: "markdown"
            )
        }

        let activeAttributes = try FileManager.default.attributesOfItem(
            atPath: dataDirectory.auditLogURL.path
        )
        #expect((activeAttributes[.size] as? Int ?? .max) <= 256)
        #expect(FileManager.default.fileExists(
            atPath: dataDirectory.auditLogURL.path + ".1"
        ))
        #expect(FileManager.default.fileExists(
            atPath: dataDirectory.auditLogURL.path + ".2"
        ))
        #expect(!FileManager.default.fileExists(
            atPath: dataDirectory.auditLogURL.path + ".3"
        ))
    }

    @Test("Independent logger actors coordinate one process-owned log")
    func coordinatesIndependentLoggers() async throws {
        let root = NSTemporaryDirectory() + "AuditLoggerTests-\(UUID().uuidString)"
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let first = AuditLogger(
            dataDirectory: dataDirectory,
            maximumBytes: 1024 * 1024,
            coordinateAcrossProcesses: true
        )
        let second = AuditLogger(
            dataDirectory: dataDirectory,
            maximumBytes: 1024 * 1024,
            coordinateAcrossProcesses: true
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<25 {
                group.addTask {
                    await first.log(
                        operation: .read,
                        path: "notes/first-\(index).md"
                    )
                }
                group.addTask {
                    await second.log(
                        operation: .read,
                        path: "notes/second-\(index).md"
                    )
                }
            }
        }

        let contents = try String(
            contentsOf: dataDirectory.auditLogURL,
            encoding: .utf8
        )
        #expect(contents.split(separator: "\n").count == 50)
        #expect(contents.contains("notes/first-0.md"))
        #expect(contents.contains("notes/second-24.md"))
    }
}
