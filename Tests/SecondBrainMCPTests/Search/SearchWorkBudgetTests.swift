import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Search attempted work budgets` {
    private final class PageSource: PDFSearchTextDocument, @unchecked Sendable {
        let pageCount: Int
        let failsLastPage: Bool
        private let lock = NSLock()
        private var count = 0
        init(pageCount: Int, failsLastPage: Bool = false) {
            self.pageCount = pageCount
            self.failsLastPage = failsLastPage
        }
        func text(at index: Int) -> String? {
            lock.withLock { count += 1 }
            return failsLastPage && index == pageCount - 1 ? nil : "needle needle"
        }
        var reads: Int { lock.withLock { count } }
    }

    @Test
    func `Global page work stops before extracting beyond the atom ceiling`() async throws {
        let root = try vault(files: 2)
        defer { removeSearchFixture(root) }
        let pages = PageSource(pageCount: 60_000)
        let search = engine(root, pages: pages)
        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await search.search(VaultSearchRequest(location: .references, query: "needle"))
        }
        #expect(pages.reads <= SearchRequestLimits.maximumAtoms)
    }

    @Test
    func `Failed PDFs do not refund attempted page work`() async throws {
        let root = try vault(files: 3)
        defer { removeSearchFixture(root) }
        let pages = PageSource(pageCount: 40_000, failsLastPage: true)
        let search = engine(root, pages: pages)
        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await search.search(VaultSearchRequest(location: .references, query: "needle"))
        }
        #expect(pages.reads <= SearchRequestLimits.maximumAtoms)
    }

    @Test
    func `A late failing PDF cannot evict healthy results or contribute cursor atoms`() async throws {
        let root = try vault(files: 1)
        defer { removeSearchFixture(root) }
        // Use a JSON source alongside PDF under one explicitly registered test area.
        try Data("{\"text\":\"needle\"}".utf8).write(to: root.appendingPathComponent("references/a.json"))
        try Data("{\"text\":\"needle\"}".utf8).write(to: root.appendingPathComponent("references/b.json"))
        let pages = PageSource(pageCount: 2, failsLastPage: true)
        let search = engine(root, pages: pages)
        let first = try await search.search(
            VaultSearchRequest(location: .references, query: "needle", limit: 1)
        )
        #expect(first.results.map(\.path) == ["references/a.json"])
        #expect(first.coverage.complete == false)
        #expect(first.coverage.failedFiles == 1)
        let cursor = try #require(first.nextCursor)
        let second = try await search.search(
            VaultSearchRequest(location: .references, query: "needle", limit: 1, cursor: cursor)
        )
        #expect(second.results.map(\.path) == ["references/b.json"])
        #expect(second.nextCursor == nil)
    }

    private func vault(files: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchWorkBudgetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("references"), withIntermediateDirectories: true
        )
        for index in 0..<files {
            // The injected framework boundary supplies deterministic PDF pages.
            try Data("fixture \(index)".utf8).write(
                to: root.appendingPathComponent("references/z\(index).pdf")
            )
        }
        return root
    }

    private func engine(_ root: URL, pages: PageSource) -> VaultSearchEngine {
        let provider = PDFSearchAtomProvider(
            cacheRoot: root.appendingPathComponent("cache"),
            admission: PDFReadAdmission(), openDocument: { _ in pages }
        )
        return VaultSearchEngine(source: SearchCorpusBuilder(
            vaultPath: root.path,
            capabilities: FileCapabilities(formats: [
                .init(format: .pdf, operations: [.read: [.references]]),
                .init(format: .json, operations: [.read: [.references]]),
            ]),
            captureStore: searchCaptureFixture(root),
            access: VaultAccessCoordinator(lockURL: root.appendingPathComponent(".vault-access.lock")),
            customProviders: [.pdf: provider]
        ))
    }
}
