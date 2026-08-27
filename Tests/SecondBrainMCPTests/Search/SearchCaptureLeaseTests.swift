import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct SearchCaptureLeaseTests {
    private final class AccessProbe: VaultAccessCoordinating, @unchecked Sendable {
        enum Failure: Error { case writerBlockedBySearchProcessing }
        private let lock = NSLock()
        private var reading = false
        var isReading: Bool { lock.withLock { reading } }
        func withRead<Result: Sendable>(
            _ operation: @escaping @Sendable () async throws -> Result
        ) async throws -> Result {
            lock.withLock { reading = true }
            defer { lock.withLock { reading = false } }
            return try await operation()
        }
        func withMutation<Result: Sendable>(
            _ operation: @escaping @Sendable () async throws -> Result
        ) async throws -> Result {
            guard !isReading else { throw Failure.writerBlockedBySearchProcessing }
            return try await operation()
        }
    }

    private struct LeaseCheckingProvider: SearchAtomProvider {
        let access: AccessProbe
        func atoms(for target: ReadableFileTarget, snapshot: FileSnapshot) async throws -> [SearchAtom] {
            #expect(!access.isReading, "Extraction and ranking must not extend the capture lease")
            return try await TextSearchAtomProvider().atoms(for: target, snapshot: snapshot)
        }
    }

    @Test
    func extractionDoesNotHoldTheVaultLease() async throws {
        let root = try fixture()
        defer { removeSearchFixture(root) }
        let access = AccessProbe()
        let source = builder(root, access)
        let result = try await VaultSearchEngine(source: source).search(
            VaultSearchRequest(location: .notes, query: "needle")
        )
        #expect(result.results.map(\.path) == ["notes/a.md", "notes/b.md"])
        #expect(result.coverage.complete)
    }

    @Test
    func writerCanChangeLaterSourceWhileResultsUseTheCompleteCapturedView() async throws {
        let root = try fixture()
        defer { removeSearchFixture(root) }
        let access = AccessProbe()
        let source = builder(root, access)
        let collected = SearchDocumentCollector()
        try await source.scan(VaultSearchRequest(location: .notes, query: "needle")) { document in
            if document.path == "notes/a.md" {
                try await access.withMutation {
                    try Data("changed after capture".utf8).write(
                        to: root.appendingPathComponent("notes/b.md"), options: .atomic
                    )
                }
            }
            await collected.append(document)
        }
        let documents = await collected.documents
        #expect(documents.flatMap(\.atoms).map(\.text) == ["needle a", "needle b"])
        #expect(try String(contentsOf: root.appendingPathComponent("notes/b.md"), encoding: .utf8)
            == "changed after capture")
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchCaptureLeaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"),
                                                withIntermediateDirectories: true)
        try Data("needle a".utf8).write(to: root.appendingPathComponent("notes/a.md"))
        try Data("needle b".utf8).write(to: root.appendingPathComponent("notes/b.md"))
        return root
    }

    private func builder(_ root: URL, _ access: AccessProbe) -> SearchCorpusBuilder {
        SearchCorpusBuilder(
            vaultPath: root.path,
            capabilities: FileCapabilities(formats: [
                .init(format: .markdown, operations: [.read: [.notes]]),
            ]),
            captureStore: searchCaptureFixture(root), access: access,
            textProvider: LeaseCheckingProvider(access: access)
        )
    }
}
