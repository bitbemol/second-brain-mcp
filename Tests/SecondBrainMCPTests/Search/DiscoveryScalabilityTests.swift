import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Discovery scalability regressions` {
    private actor Source: ArraySearchAtomSource {
        let values: [SearchAtom]
        private(set) var reads = 0
        init(_ values: [SearchAtom]) { self.values = values }
        func atoms(in location: VaultArea) async throws -> [SearchAtom] {
            reads += 1
            return values
        }
    }

    @Test
    func `Malformed cursor is rejected without opening the corpus`() async throws {
        let source = Source([])
        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await VaultSearchEngine(source: source).search(
                VaultSearchRequest(location: .notes, query: "needle", cursor: "not-a-cursor")
            )
        }
        #expect(await source.reads == 0)
    }

    @Test
    func `Long Canvas identifiers produce usable bounded cursors`() async throws {
        let identifiers = [String(repeating: "é", count: 700), "😀"]
        let source = Source(identifiers.map {
            SearchAtom(locator: VaultSearchResult(
                path: "notes/board.canvas", format: .canvas,
                canvasNodeID: $0, canvasField: "text"
            ), text: "needle", metadata: nil)
        })
        let engine = VaultSearchEngine(source: source)
        let first = try await engine.search(
            VaultSearchRequest(location: .notes, query: "needle", limit: 1)
        )
        let cursor = try #require(first.nextCursor)
        #expect(cursor.utf8.count <= SearchRequestLimits.maximumCursorBytes)
        let second = try await engine.search(
            VaultSearchRequest(location: .notes, query: "needle", limit: 1, cursor: cursor)
        )
        #expect(Set((first.results + second.results).compactMap(\.canvasNodeID)) == Set(identifiers))
        #expect(second.nextCursor == nil)
    }

    @Test
    func `Healthy results disclose incomplete coverage for malformed files`() async throws {
        let root = try makeVault()
        defer { removeSearchFixture(root) }
        try Data("needle".utf8).write(to: root.appendingPathComponent("notes/healthy.md"))
        try Data([0xff]).write(to: root.appendingPathComponent("notes/broken.md"))
        let result = try await engine(root).search(
            VaultSearchRequest(location: .notes, query: "needle")
        )
        #expect(result.results.map(\.path) == ["notes/healthy.md"])
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        )
        let coverage = try #require(object["coverage"] as? [String: Any])
        #expect(coverage["complete"] as? Bool == false)
        #expect(coverage["failed_files"] as? Int == 1)
        let samples = try #require(coverage["samples"] as? [[String: Any]])
        #expect(samples.first?["path"] as? String == "notes/broken.md")
        #expect(samples.first?["reason"] as? String == "invalid_document")
    }

    @Test
    func `Search reaches valid notes beyond the former aggregate byte ceiling`() async throws {
        let root = try makeVault()
        defer { removeSearchFixture(root) }
        let filler = Data(String(repeating: "x", count: 1024 * 1024).utf8)
        for index in 0..<65 {
            try filler.write(to: root.appendingPathComponent(
                String(format: "notes/%03d.md", index)
            ))
        }
        try Data("unique-late-needle".utf8).write(to: root.appendingPathComponent("notes/z.md"))
        let result = try await engine(root).search(
            VaultSearchRequest(location: .notes, query: "unique-late-needle")
        )
        #expect(result.results.map(\.path) == ["notes/z.md"])
    }

    private enum UnexpectedFailure: Error { case infrastructure }
    private struct FailingProvider: SearchAtomProvider {
        func atoms(for target: ReadableFileTarget, snapshot: FileSnapshot) async throws -> [SearchAtom] {
            throw UnexpectedFailure.infrastructure
        }
    }

    @Test
    func `Unknown provider failures are not silently reported as empty results`() async throws {
        let root = try makeVault()
        defer { removeSearchFixture(root) }
        try Data("needle".utf8).write(to: root.appendingPathComponent("notes/a.md"))
        let source = SearchCorpusBuilder(
            vaultPath: root.path,
            capabilities: FileCapabilities(formats: [
                .init(format: .markdown, operations: [.read: [.notes]]),
            ]),
            captureStore: searchCaptureFixture(root),
            access: VaultAccessCoordinator(lockURL: root.appendingPathComponent(".vault-access.lock")),
            textProvider: FailingProvider()
        )
        await #expect(throws: UnexpectedFailure.self) {
            _ = try await VaultSearchEngine(source: source).search(
                VaultSearchRequest(location: .notes, query: "needle")
            )
        }
    }

    @Test
    func `Raw source changes invalidate cursors even when searchable text is unchanged`() async throws {
        let root = try makeVault()
        defer { removeSearchFixture(root) }
        let firstPath = root.appendingPathComponent("notes/a.md")
        try Data("---\nunused: original\n---\nneedle".utf8).write(to: firstPath)
        try Data("needle".utf8).write(to: root.appendingPathComponent("notes/b.md"))
        let search = engine(root)
        let first = try await search.search(
            VaultSearchRequest(location: .notes, query: "needle", limit: 1)
        )
        let cursor = try #require(first.nextCursor)
        try Data("---\nunused: changed\n---\nneedle".utf8).write(to: firstPath)
        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await search.search(
                VaultSearchRequest(location: .notes, query: "needle", limit: 1, cursor: cursor)
            )
        }
    }

    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscoveryScalabilityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"), withIntermediateDirectories: true
        )
        return root
    }

    private func engine(_ root: URL) -> VaultSearchEngine {
        VaultSearchEngine(source: SearchCorpusBuilder(
            vaultPath: root.path,
            capabilities: FileCapabilities(formats: [
                .init(format: .markdown, operations: [.read: [.notes]]),
            ]),
            captureStore: searchCaptureFixture(root),
            access: VaultAccessCoordinator(lockURL: root.appendingPathComponent(".vault-access.lock"))
        ))
    }
}
