import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `PDF search atom provider` {
    @Test
    func `Produces and caches one atom per physical page`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let references = root.appendingPathComponent("references", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: references,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let data = try generatedSearchPDF(pages: [
            "First searchable page",
            "Second searchable page",
        ])
        let file = references.appendingPathComponent("book.pdf")
        try data.write(to: file)
        let target = try ReadableFileTarget.resolve(
            path: "references/book.pdf",
            format: .pdf,
            vaultPath: root.path
        )
        let provider = PDFSearchAtomProvider(
            cacheRoot: cache,
            admission: PDFReadAdmission()
        )
        let snapshot = FileSnapshot(data: data, modifiedDate: nil)
        let first = try await provider.atoms(for: target, snapshot: snapshot)
        let cached = try await provider.atoms(for: target, snapshot: snapshot)

        #expect(first.count == 2)
        #expect(first.map { $0.locator.page } == [1, 2])
        #expect(first[0].text.contains("First searchable page"))
        #expect(cached.map(\.text) == first.map(\.text))
    }
}
