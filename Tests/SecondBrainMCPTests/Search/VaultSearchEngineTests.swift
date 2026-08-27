import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Vault search engine` {
    private struct StubSource: ArraySearchAtomSource {
        let values: [VaultArea: [SearchAtom]]
        func atoms(in location: VaultArea) async throws -> [SearchAtom] {
            values[location] ?? []
        }
    }

    private struct ControlledMatchingStrategy: SearchMatchingStrategy {
        func rank(query: String, in text: String) -> SearchRank? {
            query == "all"
                ? SearchRank(exactPhrase: false, occurrenceCount: 1)
                : nil
        }
    }

    private actor MutableSource: ArraySearchAtomSource {
        private var values: [VaultArea: [SearchAtom]]

        init(values: [VaultArea: [SearchAtom]]) {
            self.values = values
        }

        func atoms(in location: VaultArea) async throws -> [SearchAtom] {
            values[location] ?? []
        }

        func replace(_ atoms: [SearchAtom], in location: VaultArea) {
            values[location] = atoms
        }
    }

    private func note(
        _ path: String,
        text: String,
        tags: Set<String> = [],
        created: String? = nil
    ) -> SearchAtom {
        SearchAtom(
            locator: VaultSearchResult(path: path, format: .markdown),
            text: text,
            metadata: SearchAtomMetadata(tags: tags, created: created)
        )
    }

    @Test
    func `Text is searched but only note locators are returned`() async throws {
        let engine = VaultSearchEngine(source: StubSource(values: [
            .notes: [
                note("notes/actors.md", text: "Swift actors isolate mutable state"),
                note("notes/other.md", text: "Gardening"),
            ],
            .references: [
                SearchAtom(
                    locator: VaultSearchResult(
                        path: "references/concurrency.pdf",
                        format: .pdf,
                        page: 4
                    ),
                    text: "Swift actors",
                    metadata: nil
                ),
            ],
        ]))
        let response = try await engine.search(VaultSearchRequest(
            location: .notes,
            query: "swift actors"
        ))
        #expect(response.results == [
            VaultSearchResult(path: "notes/actors.md", format: .markdown),
        ])
    }

    @Test
    func `Tags and created dates filter notes without a text query`() async throws {
        let engine = VaultSearchEngine(source: StubSource(values: [
            .notes: [
                note(
                    "notes/one.md",
                    text: "first",
                    tags: ["swift", "architecture"],
                    created: "2026-02-10"
                ),
                note(
                    "notes/two.md",
                    text: "second",
                    tags: ["swift"],
                    created: "2025-12-31"
                ),
            ],
        ]))
        let response = try await engine.search(VaultSearchRequest(
            location: .notes,
            tags: ["ARCHITECTURE", "Swift"],
            createdFrom: "2026-01-01",
            createdThrough: "2026-12-31"
        ))
        #expect(response.results.map(\.path) == ["notes/one.md"])
    }

    @Test
    func `Cursor pagination eventually discovers every matching atom`() async throws {
        let atoms = (1...7).map {
            note("notes/\($0).md", text: "shared phrase")
        }
        let engine = VaultSearchEngine(source: StubSource(values: [.notes: atoms]))
        var cursor: String?
        var paths: [String] = []
        repeat {
            let page = try await engine.search(VaultSearchRequest(
                location: .notes,
                query: "shared",
                limit: 2,
                cursor: cursor
            ))
            paths.append(contentsOf: page.results.map(\.path))
            cursor = page.nextCursor
        } while cursor != nil

        #expect(paths.count == 7)
        #expect(Set(paths) == Set(atoms.map { $0.locator.path }))
    }

    @Test
    func `Cursor cannot continue a different request`() async throws {
        let engine = VaultSearchEngine(source: StubSource(values: [
            .notes: [
                note("notes/one.md", text: "alpha beta"),
                note("notes/two.md", text: "alpha beta"),
            ],
        ]))
        let first = try await engine.search(VaultSearchRequest(
            location: .notes,
            query: "alpha",
            limit: 1
        ))
        let cursor = try #require(first.nextCursor)
        await #expect(throws: VaultSearchRequestError.self) {
            try await engine.search(VaultSearchRequest(
                location: .notes,
                query: "beta",
                limit: 1,
                cursor: cursor
            ))
        }
    }

    @Test
    func `Cursor rejects a forged anchor that is not a matching atom`() async throws {
        let atoms = [
            note("notes/one.md", text: "anything"),
            note("notes/two.md", text: "anything"),
        ]
        let request = VaultSearchRequest(location: .notes, query: "all", limit: 1)
        let engine = VaultSearchEngine(
            source: StubSource(values: [.notes: atoms]),
            strategy: ControlledMatchingStrategy()
        )
        let first = try await engine.search(request)
        let cursor = try #require(first.nextCursor)
        let observed = try SearchCursorCodec.decode(
            cursor, requestHash: SearchCursorCodec.requestHash(request)
        )
        let forged = try SearchCursorCodec.encode(
            requestHash: observed.requestHash,
            corpusHash: observed.corpusHash,
            ranked: RankedSearchLocator(
                locator: VaultSearchResult(path: "notes/zero.md", format: .markdown),
                rank: observed.rank, ordinal: observed.ordinal
            )
        )

        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await engine.search(VaultSearchRequest(
                location: .notes,
                query: "all",
                limit: 1,
                cursor: forged
            ))
        }
    }

    @Test
    func `Cursor is rejected when the searchable corpus changes`() async throws {
        let original = [
            note("notes/2.md", text: "shared phrase"),
            note("notes/3.md", text: "shared phrase"),
        ]
        let source = MutableSource(values: [.notes: original])
        let engine = VaultSearchEngine(source: source)
        let first = try await engine.search(VaultSearchRequest(
            location: .notes,
            query: "shared",
            limit: 1
        ))
        let cursor = try #require(first.nextCursor)

        await source.replace(
            [note("notes/1.md", text: "shared phrase")] + original,
            in: .notes
        )

        do {
            _ = try await engine.search(VaultSearchRequest(
                location: .notes,
                query: "shared",
                limit: 1,
                cursor: cursor
            ))
            Issue.record("Expected the cursor to be rejected after a corpus change")
        } catch let error as VaultSearchRequestError {
            #expect(
                error.description
                    == "Search cursor is stale because the vault changed; restart the search"
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `Reference metadata filters are rejected`() async throws {
        let engine = VaultSearchEngine(source: StubSource(values: [:]))
        await #expect(throws: VaultSearchRequestError.self) {
            try await engine.search(VaultSearchRequest(
                location: .references,
                tags: ["swift"]
            ))
        }
    }

    @Test
    func `Records bounded search page cost when every atom matches`() async throws {
        let atoms = (0..<50_000).map {
            let value = ($0 * 7_919) % 50_000
            return note(
                "notes/\(String(format: "%05d", value)).md",
                text: "searchable value"
            )
        }
        let engine = VaultSearchEngine(
            source: StubSource(values: [.notes: atoms]),
            strategy: ControlledMatchingStrategy()
        )
        let clock = ContinuousClock()

        let noMatchStart = clock.now
        _ = try await engine.search(VaultSearchRequest(
            location: .notes,
            query: "none",
            limit: 20
        ))
        let noMatchTime = noMatchStart.duration(to: clock.now)

        let allMatchStart = clock.now
        let response = try await engine.search(VaultSearchRequest(
            location: .notes,
            query: "all",
            limit: 20
        ))
        let allMatchTime = allMatchStart.duration(to: clock.now)
        #expect(response.results.count == 20)
        #expect(response.results.first?.path == "notes/00000.md")

        let ratio = milliseconds(allMatchTime) / milliseconds(noMatchTime)
        print(
            "SEARCH_PAGE_BASELINE no_match_ms=\(formatted(noMatchTime)) "
                + "all_match_ms=\(formatted(allMatchTime)) "
                + "ratio=\(String(format: "%.3f", ratio))"
        )
        #expect(
            ratio < 1.15,
            "Search sorts every match even though one bounded page needs only limit + 1"
        )
    }

    @Test
    func `Canvas node locators remain distinct across cursor pages`() async throws {
        let atoms = [
            SearchAtom(
                locator: VaultSearchResult(
                    path: "notes/board.canvas",
                    format: .canvas,
                    canvasNodeID: "group-node",
                    canvasField: "label"
                ),
                text: "shared phrase",
                metadata: nil
            ),
            SearchAtom(
                locator: VaultSearchResult(
                    path: "notes/board.canvas",
                    format: .canvas,
                    canvasNodeID: "text-node",
                    canvasField: "text"
                ),
                text: "shared phrase",
                metadata: nil
            ),
        ]
        let engine = VaultSearchEngine(source: StubSource(values: [.notes: atoms]))
        let first = try await engine.search(VaultSearchRequest(
            location: .notes,
            query: "shared",
            limit: 1
        ))
        let cursor = try #require(first.nextCursor)
        let second = try await engine.search(VaultSearchRequest(
            location: .notes,
            query: "shared",
            limit: 1,
            cursor: cursor
        ))

        #expect((first.results + second.results).map(\.canvasNodeID)
            == ["group-node", "text-node"])
        #expect((first.results + second.results).map(\.canvasField)
            == ["label", "text"])
        #expect(second.nextCursor == nil)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func formatted(_ duration: Duration) -> String {
        String(format: "%.3f", milliseconds(duration))
    }
}

@Suite
struct `Vault link query traversal and pagination` {
    @Test
    func `Backlinks resolve ambiguous basenames from each source directory`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Local", to: "notes/project/Target.md", under: root)
        try write("# Remote", to: "notes/archive/Target.md", under: root)
        try write("[[Target]]", to: "notes/project/Source.md", under: root)
        try write("[[Target]]", to: "notes/archive/Source.md", under: root)

        let response = try await makeEngine(root: root).query(LinkQueryRequest(
            direction: .backlinks,
            target: "Target"
        ))

        #expect(response.results.map(\.sourcePath) == [
            "notes/archive/Source.md",
            "notes/project/Source.md",
        ])
        #expect(response.results.map(\.resolvedPath) == [
            "notes/archive/Target.md",
            "notes/project/Target.md",
        ])
        #expect(response.results.map(\.ambiguous) == [false, false])
    }

    @Test
    func `Outgoing returns aliases embeds explicit paths and unresolved links without content`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Target", to: "notes/project/Target.md", under: root)
        try write("# Other", to: "notes/elsewhere/Other.md", under: root)
        try write("image", to: "notes/assets/diagram.png", under: root)
        try write(
            "[[Target|display]] ![[assets/diagram.png|diagram]] "
                + "[[notes/elsewhere/Other.md]] [[Missing]]",
            to: "notes/project/Source.md",
            under: root
        )

        let response = try await makeEngine(root: root).query(LinkQueryRequest(
            direction: .outgoing,
            target: "notes/project/Source.md"
        ))

        #expect(response.results.map(\.target) == [
            "Target", "assets/diagram.png", "notes/elsewhere/Other.md", "Missing",
        ])
        #expect(response.results.map(\.resolvedPath) == [
            "notes/project/Target.md",
            "notes/assets/diagram.png",
            "notes/elsewhere/Other.md",
            nil,
        ])
        #expect(response.results.map(\.kind) == [.link, .embed, .link, .link])
        #expect(response.results.map(\.alias) == ["display", "diagram", nil, nil])
        #expect(response.results.map(\.occurrence) == [1, 2, 3, 4])
    }

    @Test
    func `Shrinking backlink results makes a continuation stale not malformed`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Target", to: "notes/Target.md", under: root)
        try write("[[Target]]", to: "notes/A.md", under: root)
        try write("[[Target]]", to: "notes/B.md", under: root)
        let engine = makeEngine(root: root)
        let first = try await engine.query(LinkQueryRequest(
            direction: .backlinks,
            target: "Target",
            limit: 1
        ))
        let cursor = try #require(first.nextCursor)

        try write("No links remain", to: "notes/B.md", under: root)

        do {
            _ = try await engine.query(LinkQueryRequest(
                direction: .backlinks,
                target: "Target",
                limit: 1,
                cursor: cursor
            ))
            Issue.record("Expected a stale cursor")
        } catch let error as LinkQueryError {
            guard case .staleCursor = error else {
                Issue.record("Expected staleCursor, received \(error)")
                return
            }
        }
    }

    private func makeEngine(root: URL) -> VaultLinkQueryEngine {
        let capabilities = FileCapabilities(formats: [
            .init(format: .markdown, operations: [.read: [.notes]]),
            .init(format: .png, operations: [.read: [.notes, .references]]),
            .init(format: .pdf, operations: [.read: [.references]]),
        ])
        return VaultLinkQueryEngine(
            vaultPath: root.path,
            capabilities: capabilities,
            store: VaultCRUDStore(vaultPath: root.path),
            access: VaultAccessCoordinator(
                lockURL: root.appendingPathComponent(".vault-access.lock")
            )
        )
    }

    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultLinkQueryEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("references", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func write(_ content: String, to path: String, under root: URL) throws {
        let destination = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: destination)
    }
}
