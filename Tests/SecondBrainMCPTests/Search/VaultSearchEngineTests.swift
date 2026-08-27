import Foundation
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

    private struct ControlledMatchingStrategy: SearchMatchingStrategy {
        func rank(query: String, in text: String) -> SearchRank? {
            query == "all"
                ? SearchRank(exactPhrase: false, occurrenceCount: 1)
                : nil
        }
    }

    private actor MutableSource: VaultSearchAtomSource {
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

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func formatted(_ duration: Duration) -> String {
        String(format: "%.3f", milliseconds(duration))
    }
}
