import CryptoKit
import Foundation

enum SearchCursorCodec {
    struct Payload: Codable, Sendable {
        let requestHash: String
        let exactPhrase: Bool
        let occurrenceCount: Int
        let path: String
        let format: FileFormat
        let page: Int?
    }

    private struct Criteria: Codable {
        let location: VaultArea
        let query: String?
        let tags: [String]
        let createdFrom: String?
        let createdThrough: String?
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

    static func encode(
        requestHash: String,
        ranked: RankedSearchLocator
    ) throws -> String {
        let payload = Payload(
            requestHash: requestHash,
            exactPhrase: ranked.rank.exactPhrase,
            occurrenceCount: ranked.rank.occurrenceCount,
            path: ranked.locator.path,
            format: ranked.locator.format,
            page: ranked.locator.page
        )
        return try JSONEncoder().encode(payload)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ cursor: String, requestHash: String) throws -> Payload {
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
              payload.occurrenceCount >= 0,
              !payload.path.isEmpty,
              payload.page.map({ $0 > 0 }) ?? true else {
            throw VaultSearchRequestError.invalidCursor
        }
        return payload
    }
}
