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
}

struct SearchRank: Codable, Equatable, Sendable {
    let exactPhrase: Bool
    let occurrenceCount: Int
}

struct RankedSearchLocator: Sendable {
    let locator: VaultSearchResult
    let rank: SearchRank
}

protocol SearchMatchingStrategy: Sendable {
    func rank(query: String, in text: String) -> SearchRank?
}
