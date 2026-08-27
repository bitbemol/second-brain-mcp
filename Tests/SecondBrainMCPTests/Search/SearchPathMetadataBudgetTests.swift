import Darwin
import Foundation
import Testing
@testable import second_brain_mcp

@Suite("Search path metadata resource bounds")
struct SearchPathMetadataBudgetTests {
    @Test("Candidate metadata is bounded before opening source content")
    func candidateMetadataBudgetFailsBeforeSourceReads() async throws {
        let root = try fixture()
        defer { removeSearchFixture(root) }
        let relative = "notes/retained-source.md"
        let file = root.appendingPathComponent(relative)
        try Data("needle".utf8).write(to: file)
        // Match the captured manifest representation: relative and absolute paths,
        // format, fixed revision and fixed per-entry fields.
        let target = try ReadableFileTarget.resolve(
            path: relative, format: .markdown, vaultPath: root.path
        )
        let allowance = target.relativePath.utf8.count + target.url.path.utf8.count
            + target.format.rawValue.utf8.count + 71
        let opened = OpenCounter()
        let control = builder(root, opened: opened, candidateBytes: allowance)
        let response = try await VaultSearchEngine(source: control).search(
            VaultSearchRequest(location: .notes, query: "needle")
        )
        #expect(response.results.map(\.path) == [relative])
        #expect(opened.value == 1)

        let limited = builder(root, opened: opened, candidateBytes: allowance - 1)
        do {
            _ = try await VaultSearchEngine(source: limited).search(
                VaultSearchRequest(location: .notes, query: "needle")
            )
            Issue.record("Expected candidate metadata exhaustion before source capture")
        } catch VaultSearchRequestError.workBudgetExceeded {
            // Whole-request work failure, never successful partial coverage.
        }
        #expect(opened.value == 1, "The rejected request must not open source content")
    }

    @Test("Traversal path bytes include unsupported entries across recursive branches")
    func traversalPathBudgetIncludesUnsupportedBranches() async throws {
        let root = try fixture()
        defer { removeSearchFixture(root) }
        let directories = ["notes/first", "notes/second"].map { root.appendingPathComponent($0) }
        let files = directories.map { $0.appendingPathComponent("unsupported-entry.bin") }
        for (directory, file) in zip(directories, files) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("not an indexed format".utf8).write(to: file)
        }
        let allowance = (directories + files).reduce(0) { $0 + $1.path.utf8.count }
        let opened = OpenCounter()
        let control = builder(root, opened: opened, traversalBytes: allowance)
        let response = try await VaultSearchEngine(source: control).search(
            VaultSearchRequest(location: .notes, query: "needle")
        )
        #expect(response.results.isEmpty)
        #expect(response.coverage.complete)

        let limited = builder(root, opened: opened, traversalBytes: allowance - 1)
        do {
            _ = try await VaultSearchEngine(source: limited).search(
                VaultSearchRequest(location: .notes, query: "needle")
            )
            Issue.record("Expected aggregate traversal path exhaustion despite no eligible sources")
        } catch VaultSearchRequestError.workBudgetExceeded {
            // A per-directory reset must not bypass the complete traversal budget.
        }
        #expect(opened.value == 0)
    }

    private func fixture() throws -> URL {
        // Resolve the existing temporary parent before adding a not-yet-existing child.
        // Foundation may preserve /var for nonexistent paths while enumeration uses /private/var.
        guard let canonical = Darwin.realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("SearchPathMetadataBudget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"), withIntermediateDirectories: true
        )
        return root
    }

    private func builder(
        _ root: URL,
        opened: OpenCounter,
        traversalBytes: Int = 8 * 1_024 * 1_024,
        candidateBytes: Int = 8 * 1_024 * 1_024
    ) -> SearchCorpusBuilder {
        SearchCorpusBuilder(
            vaultPath: root.path,
            capabilities: FileCapabilities(formats: [
                .init(format: .markdown, operations: [.read: [.notes]])
            ]),
            captureStore: searchCaptureFixture(root, observer: { _ in opened.increment() }),
            access: VaultAccessCoordinator(lockURL: root.appendingPathComponent(".vault-access.lock")),
            maximumTraversalPathBytes: traversalBytes,
            maximumCandidateMetadataBytes: candidateBytes
        )
    }

    private final class OpenCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }
}
