import Foundation
import Testing
@testable import second_brain_mcp

private struct OversizedSearchAtomProvider: SearchAtomProvider {
    func atoms(
        for target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) async throws -> [SearchAtom] {
        Array(repeating: SearchAtom(
            locator: VaultSearchResult(path: target.relativePath, format: target.format),
            text: "bounded",
            metadata: nil
        ), count: 100_001)
    }
}

@Suite
struct `Search corpus resilience` {
    @Test
    func `One malformed note does not make healthy notes undiscoverable`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchCorpusBuilderTests-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: notes,
            withIntermediateDirectories: true
        )
        defer { removeSearchFixture(root) }

        try Data("healthy searchable text".utf8).write(
            to: notes.appendingPathComponent("healthy.md")
        )
        try Data([0xFF]).write(
            to: notes.appendingPathComponent("malformed.md")
        )

        let capabilities = FileCapabilities(formats: [
            .init(
                format: .markdown,
                operations: [.read: [.notes]]
            ),
        ])
        let builder = SearchCorpusBuilder(
            vaultPath: root.path,
            capabilities: capabilities,
            captureStore: searchCaptureFixture(root),
            access: VaultAccessCoordinator(
                lockURL: root.appendingPathComponent(".vault-access.lock")
            )
        )

        let atoms = try await SearchDocumentCollector.atoms(from: builder, in: .notes)

        #expect(atoms.map(\.locator.path) == ["notes/healthy.md"])
        #expect(atoms.map(\.text) == ["healthy searchable text"])
    }

    @Test
    func `Canvas search returns one atomic locator per searchable node field`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasSearchCorpusBuilderTests-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: notes,
            withIntermediateDirectories: true
        )
        defer { removeSearchFixture(root) }

        let canvas = """
        {
          "nodes": [
            {
              "id": "text-node",
              "type": "text",
              "text": "alpha needle",
              "x": 0,
              "y": 0,
              "width": 100,
              "height": 100
            },
            {
              "id": "group-node",
              "type": "group",
              "label": "beta needle",
              "x": 120,
              "y": 0,
              "width": 100,
              "height": 100
            }
          ],
          "edges": []
        }
        """
        try Data(canvas.utf8).write(
            to: notes.appendingPathComponent("board.canvas")
        )

        let capabilities = FileCapabilities(formats: [
            .init(
                format: .canvas,
                operations: [.read: [.notes]]
            ),
        ])
        let builder = SearchCorpusBuilder(
            vaultPath: root.path,
            capabilities: capabilities,
            captureStore: searchCaptureFixture(root),
            access: VaultAccessCoordinator(
                lockURL: root.appendingPathComponent(".vault-access.lock")
            )
        )

        let atoms = try await SearchDocumentCollector.atoms(from: builder, in: .notes)

        #expect(atoms.map(\.text) == ["alpha needle", "beta needle"])
        let encoded = try JSONEncoder().encode(atoms.map(\.locator))
        let json = try JSONSerialization.jsonObject(with: encoded)
        let locators = try #require(json as? [[String: Any]])
        #expect(locators.compactMap { $0["canvas_node_id"] as? String }
            == ["text-node", "group-node"])
        #expect(locators.compactMap { $0["canvas_field"] as? String }
            == ["text", "label"])
    }

    @Test
    func `File listing is deterministic paginated and never opens PDF content`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileListingTests-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let references = root.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        defer { removeSearchFixture(root) }
        try Data("a".utf8).write(to: notes.appendingPathComponent("a.md"))
        try Data("b".utf8).write(to: notes.appendingPathComponent("b.md"))
        try Data("not a pdf".utf8).write(to: references.appendingPathComponent("broken.pdf"))

        let capabilities = FileCapabilities(formats: [
            .init(format: .markdown, operations: [.read: [.notes]]),
            .init(format: .pdf, operations: [.read: [.references]]),
        ])
        let access = VaultAccessCoordinator(
            lockURL: root.appendingPathComponent(".vault-access.lock")
        )
        let listing = VaultFileListingService(
            vaultPath: root.path,
            capabilities: capabilities,
            access: access
        )

        let first = try await listing.list(ListFilesRequest(
            area: .notes,
            limit: 1
        ))
        #expect(first.files.map(\.path) == ["notes/a.md"])
        let cursor = try #require(first.nextCursor)
        let second = try await listing.list(ListFilesRequest(
            area: .notes,
            limit: 1,
            cursor: cursor
        ))
        #expect(second.files.map(\.path) == ["notes/b.md"])
        #expect(second.nextCursor == nil)

        let referencesPage = try await listing.list(ListFilesRequest(
            area: .references
        ))
        #expect(referencesPage.files.map(\.path) == ["references/broken.pdf"])
        #expect(referencesPage.files.first?.byteCount == 9)
    }

    @Test
    func `Search rejects a provider corpus above the atom safety ceiling`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchAtomLimitTests-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { removeSearchFixture(root) }
        try Data("{}".utf8).write(to: notes.appendingPathComponent("dense.json"))

        let builder = SearchCorpusBuilder(
            vaultPath: root.path,
            capabilities: FileCapabilities(formats: [
                .init(format: .json, operations: [.read: [.notes]]),
            ]),
            captureStore: searchCaptureFixture(root),
            access: VaultAccessCoordinator(
                lockURL: root.appendingPathComponent(".vault-access.lock")
            ),
            customProviders: [.json: OversizedSearchAtomProvider()]
        )

        do {
            _ = try await SearchDocumentCollector.atoms(from: builder, in: .notes)
            Issue.record("Expected the atom safety ceiling to reject the corpus")
        } catch let error as VaultSearchRequestError {
            guard case .workBudgetExceeded = error else {
                Issue.record("Expected workBudgetExceeded, received \(error)")
                return
            }
        }
    }

    @Test
    func `File listing cursor never omits a prefix-colliding file after a directory`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileListingPrefixTests-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("notes/a", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { removeSearchFixture(root) }
        try Data("nested".utf8).write(to: nested.appendingPathComponent("nested.md"))
        try Data("sibling".utf8).write(
            to: root.appendingPathComponent("notes/a.md")
        )

        let listing = VaultFileListingService(
            vaultPath: root.path,
            capabilities: FileCapabilities(formats: [
                .init(format: .markdown, operations: [.read: [.notes]]),
            ]),
            access: VaultAccessCoordinator(
                lockURL: root.appendingPathComponent(".vault-access.lock")
            )
        )

        var discovered: [String] = []
        var cursor: String?
        repeat {
            let page = try await listing.list(ListFilesRequest(
                area: .notes,
                limit: 1,
                cursor: cursor
            ))
            discovered.append(contentsOf: page.files.map(\.path))
            cursor = page.nextCursor
        } while cursor != nil

        #expect(Set(discovered) == ["notes/a/nested.md", "notes/a.md"])
        #expect(discovered.count == 2)
    }

    @Test
    func `File listing filters directories and rejects traversal or stale cursors`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileListingPolicyTests-\(UUID().uuidString)")
        let projects = root.appendingPathComponent(
            "notes/projects/nested",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { removeSearchFixture(root) }
        try Data("direct".utf8).write(
            to: projects.deletingLastPathComponent().appendingPathComponent("direct.md")
        )
        try Data("nested".utf8).write(to: projects.appendingPathComponent("nested.md"))

        let capabilities = FileCapabilities(formats: [
            .init(format: .markdown, operations: [.read: [.notes]]),
        ])
        let listing = VaultFileListingService(
            vaultPath: root.path,
            capabilities: capabilities,
            access: VaultAccessCoordinator(
                lockURL: root.appendingPathComponent(".vault-access.lock")
            )
        )
        let direct = try await listing.list(ListFilesRequest(
            area: .notes,
            directory: "projects",
            recursive: false
        ))
        #expect(direct.files.map(\.path) == ["notes/projects/direct.md"])

        await #expect(throws: PathValidationError.self) {
            _ = try await listing.list(ListFilesRequest(
                area: .notes,
                directory: "../references"
            ))
        }

        let first = try await listing.list(ListFilesRequest(
            area: .notes,
            limit: 1
        ))
        let cursor = try #require(first.nextCursor)
        try Data("changed".utf8).write(
            to: projects.deletingLastPathComponent().appendingPathComponent("direct.md")
        )
        await #expect(throws: FileListingError.self) {
            _ = try await listing.list(ListFilesRequest(
                area: .notes,
                limit: 1,
                cursor: cursor
            ))
        }

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("notes", isDirectory: true)
        )
        await #expect(throws: FileListingError.self) {
            _ = try await listing.list(ListFilesRequest(
                area: .notes,
                limit: 1,
                cursor: cursor
            ))
        }
    }

}
