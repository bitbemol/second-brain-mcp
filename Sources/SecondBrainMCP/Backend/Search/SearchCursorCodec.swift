import CryptoKit
import Foundation

enum SearchCursorCodec {
    struct Payload: Codable, Sendable {
        let requestHash: String
        let corpusHash: String
        let exactPhrase: Bool
        let occurrenceCount: Int
        let path: String
        let format: FileFormat
        let page: Int?
        let canvasNodeID: String?
        let canvasField: String?
    }

    private struct Criteria: Codable {
        let location: VaultArea
        let query: String?
        let tags: [String]
        let createdFrom: String?
        let createdThrough: String?
    }

    private struct CorpusAtom: Codable {
        let path: String
        let format: String
        let page: Int?
        let canvasNodeID: String?
        let canvasField: String?
        let text: String
        let tags: [String]
        let created: String?
    }

    static func requestHash(_ request: VaultSearchRequest) throws -> String {
        let criteria = Criteria(
            location: request.location,
            query: request.query,
            tags: request.tags,
            createdFrom: request.createdFrom,
            createdThrough: request.createdThrough
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(criteria))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func corpusHash(_ atoms: [SearchAtom]) throws -> String {
        let corpus = atoms.map { atom in
            CorpusAtom(
                path: atom.locator.path,
                format: atom.locator.format.rawValue,
                page: atom.locator.page,
                canvasNodeID: atom.locator.canvasNodeID,
                canvasField: atom.locator.canvasField,
                text: atom.text,
                tags: atom.metadata?.tags.sorted() ?? [],
                created: atom.metadata?.created
            )
        }.sorted { lhs, rhs in
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            if lhs.format != rhs.format { return lhs.format < rhs.format }
            if lhs.page != rhs.page { return (lhs.page ?? 0) < (rhs.page ?? 0) }
            if lhs.canvasNodeID != rhs.canvasNodeID {
                return (lhs.canvasNodeID ?? "") < (rhs.canvasNodeID ?? "")
            }
            if lhs.canvasField != rhs.canvasField {
                return (lhs.canvasField ?? "") < (rhs.canvasField ?? "")
            }
            if lhs.text != rhs.text { return lhs.text < rhs.text }
            if lhs.tags != rhs.tags { return lhs.tags.lexicographicallyPrecedes(rhs.tags) }
            return (lhs.created ?? "") < (rhs.created ?? "")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(corpus))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func encode(
        requestHash: String,
        corpusHash: String,
        ranked: RankedSearchLocator
    ) throws -> String {
        let payload = Payload(
            requestHash: requestHash,
            corpusHash: corpusHash,
            exactPhrase: ranked.rank.exactPhrase,
            occurrenceCount: ranked.rank.occurrenceCount,
            path: ranked.locator.path,
            format: ranked.locator.format,
            page: ranked.locator.page,
            canvasNodeID: ranked.locator.canvasNodeID,
            canvasField: ranked.locator.canvasField
        )
        return try JSONEncoder().encode(payload)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(
        _ cursor: String,
        requestHash: String,
        corpusHash: String
    ) throws -> Payload {
        guard cursor.utf8.count <= SearchRequestLimits.maximumCursorBytes else {
            throw VaultSearchRequestError.invalidCursor
        }
        var base64 = cursor
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.requestHash == requestHash,
              payload.corpusHash.count == 64,
              payload.occurrenceCount >= 0,
              !payload.path.isEmpty,
              payload.page.map({ $0 > 0 }) ?? true else {
            throw VaultSearchRequestError.invalidCursor
        }
        guard payload.corpusHash == corpusHash else {
            throw VaultSearchRequestError.staleCursor
        }
        return payload
    }
}
