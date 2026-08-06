import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("PDFReader — read boundary")
struct PDFReaderTests {
    @Test("Reports an unreadable validated PDF target")
    func rejectsUnreadableTarget() throws {
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

        #expect(throws: VaultFileInspector.InspectionError.self) {
            try PDFReader().read(target: target)
        }
    }

    @Test("Rejects oversized PDFs before opening")
    func rejectsOversizedTarget() throws {
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

        #expect(throws: FileResourcePolicy.Violation.self) {
            try PDFReader().read(target: target)
        }
    }
}
