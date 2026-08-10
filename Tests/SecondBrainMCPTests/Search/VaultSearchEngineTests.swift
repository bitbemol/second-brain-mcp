import Testing
@testable import second_brain_mcp

@Suite
struct `Vault search engine` {
    private struct StubSource: VaultSearchAtomSource {
        let values: [VaultArea: [SearchAtom]]
        func atoms(in location: VaultArea) async throws -> [SearchAtom] {
            values[location] ?? []
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
    func `Reference metadata filters are rejected`() async throws {
        let engine = VaultSearchEngine(source: StubSource(values: [:]))
        await #expect(throws: VaultSearchRequestError.self) {
            try await engine.search(VaultSearchRequest(
                location: .references,
                tags: ["swift"]
            ))
        }
    }
}
