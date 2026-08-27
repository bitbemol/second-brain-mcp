import Foundation

struct SearchAtomMetadata: Sendable {
    let tags: Set<String>
    let created: String?
}

struct SearchAtom: Sendable {
    let locator: VaultSearchResult
    let text: String
    let metadata: SearchAtomMetadata?
}

protocol SearchAtomProvider: Sendable {
    func atoms(
        for target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) async throws -> [SearchAtom]

    func atoms(
        for target: ReadableFileTarget,
        snapshot: FileSnapshot,
        budget: SearchWorkBudget
    ) async throws -> [SearchAtom]

    func atoms(
        for target: ReadableFileTarget,
        loadSnapshot: @escaping @Sendable () async throws -> FileSnapshot,
        budget: SearchWorkBudget
    ) async throws -> [SearchAtom]
}

extension SearchAtomProvider {
    func atoms(
        for target: ReadableFileTarget,
        loadSnapshot: @escaping @Sendable () async throws -> FileSnapshot,
        budget: SearchWorkBudget
    ) async throws -> [SearchAtom] {
        try Task.checkCancellation()
        let snapshot = try await loadSnapshot()
        return try await atoms(for: target, snapshot: snapshot, budget: budget)
    }

    func atoms(
        for target: ReadableFileTarget,
        snapshot: FileSnapshot,
        budget: SearchWorkBudget
    ) async throws -> [SearchAtom] {
        let result = try await atoms(for: target, snapshot: snapshot)
        try budget.consumeAtoms(result.count)
        return result
    }
}

struct SearchRank: Codable, Equatable, Sendable {
    let exactPhrase: Bool
    let occurrenceCount: Int
}

struct RankedSearchLocator: Sendable {
    let locator: VaultSearchResult
    let rank: SearchRank
    let ordinal: Int

    init(locator: VaultSearchResult, rank: SearchRank, ordinal: Int = 0) {
        self.locator = locator
        self.rank = rank
        self.ordinal = ordinal
    }
}

protocol SearchMatchingStrategy: Sendable {
    func rank(query: String, in text: String) -> SearchRank?
    func prepare(query: String) -> @Sendable (String) -> SearchRank?
}

extension SearchMatchingStrategy {
    func prepare(query: String) -> @Sendable (String) -> SearchRank? {
        { text in rank(query: query, in: text) }
    }
}
