import Foundation
import Testing
@testable import second_brain_mcp

@Suite("PDFReader — read boundary")
struct PDFReaderTests {
    @Test("Reports an unreadable validated PDF target")
    func rejectsUnreadableTarget() async throws {
        let root = NSTemporaryDirectory() + "PDFReaderTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        let target = try ReadableFileTarget.resolve(
            path: "references/missing.pdf",
            format: .pdf,
            vaultPath: root
        )

        await #expect(throws: VaultFileInspector.InspectionError.self) {
            try await PDFReader().read(target: target)
        }
    }

    @Test("Rejects oversized PDFs before opening")
    func rejectsOversizedTarget() async throws {
        let root = NSTemporaryDirectory() + "PDFReaderSizeTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        let target = try ReadableFileTarget.resolve(
            path: "references/oversized.pdf",
            format: .pdf,
            vaultPath: root
        )
        try Data().write(to: target.url)
        let handle = try FileHandle(forWritingTo: target.url)
        try handle.truncate(atOffset: UInt64(FileFormat.pdf.maximumFileBytes + 1))
        try handle.close()

        await #expect(throws: FileResourcePolicy.Violation.self) {
            try await PDFReader().read(target: target)
        }
    }

    @Test("Rejects empty and oversized PDF queries before opening PDFKit")
    func rejectsInvalidQuery() async throws {
        let root = NSTemporaryDirectory() + "PDFReaderQueryTests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        let target = try ReadableFileTarget.resolve(
            path: "references/missing.pdf",
            format: .pdf,
            vaultPath: root
        )
        await #expect(throws: PDFReadError.self) {
            try await PDFReader().read(target: target, query: "   ")
        }
        await #expect(throws: PDFReadError.self) {
            try await PDFReader().read(
                target: target,
                query: String(
                    repeating: "x",
                    count: FileReadRequestLimits.maximumPDFQueryBytes + 1
                )
            )
        }
        await #expect(throws: PDFReadError.self) {
            try await PDFReader().read(
                target: target,
                bookPage: String(
                    repeating: "x",
                    count: FileReadRequestLimits.maximumPDFBookPageBytes + 1
                )
            )
        }
        await #expect(throws: PDFReadError.self) {
            try await PDFReader().read(
                target: target,
                pageRange: String(
                    repeating: "1",
                    count: FileReadRequestLimits.maximumPDFPageRangeBytes + 1
                )
            )
        }
    }
}
