import CryptoKit
import Foundation

enum SearchCursorCodec {
    struct Payload: Codable, Sendable {
        let version: Int
        let requestHash: String
        let corpusHash: String
        let rank: SearchRank
        let ordinal: Int
        let anchorID: String
    }

    private struct Criteria: Codable {
        let location: VaultArea
        let directory: String?
        let formats: [FileFormat]
        let query: String?
        let tags: [String]
        let createdFrom: String?
        let createdThrough: String?
    }

    static func requestHash(_ request: VaultSearchRequest) throws -> String {
        let criteria = Criteria(
            location: request.location,
            directory: request.directory,
            formats: request.formats,
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

    static func encode(
        requestHash: String, corpusHash: String, ranked: RankedSearchLocator
    ) throws -> String {
        let payload = Payload(
            version: 2, requestHash: requestHash, corpusHash: corpusHash,
            rank: ranked.rank, ordinal: ranked.ordinal,
            anchorID: SearchFingerprint.locatorID(ranked.locator)
        )
        let result = try JSONEncoder().encode(payload).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard result.utf8.count <= SearchRequestLimits.maximumCursorBytes else {
            throw VaultSearchRequestError.invalidCursor
        }
        return result
    }

    static func decode(_ cursor: String, requestHash: String) throws -> Payload {
        guard !cursor.isEmpty,
              cursor.utf8.count <= SearchRequestLimits.maximumCursorBytes,
              cursor.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || $0 == 45 || $0 == 95
              }) else {
            throw VaultSearchRequestError.invalidCursor
        }
        var base64 = cursor.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 2,
              payload.requestHash == requestHash,
              isDigest(payload.corpusHash), isDigest(payload.anchorID),
              payload.rank.occurrenceCount >= 0,
              (0..<SearchRequestLimits.maximumAtoms).contains(payload.ordinal) else {
            throw VaultSearchRequestError.invalidCursor
        }
        return payload
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
