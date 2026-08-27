import CryptoKit
import Foundation

// MARK: - Link-query cursor

enum LinkQueryCursorCodec {
    struct Payload: Codable, Sendable {
        let requestHash: String
        let corpusHash: String
        let offset: Int
    }

    private struct Criteria: Codable {
        let direction: LinkQueryDirection
        let target: String
        let fromPath: String?
    }

    static func requestHash(
        direction: LinkQueryDirection,
        target: String,
        fromPath: String?
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Criteria(
            direction: direction,
            target: target,
            fromPath: fromPath
        ))
        return hex(SHA256.hash(data: data))
    }

    static func corpusHash(_ results: [LinkQueryResult]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return hex(SHA256.hash(data: try encoder.encode(results)))
    }

    static func encode(
        requestHash: String,
        corpusHash: String,
        offset: Int
    ) throws -> String {
        let data = try JSONEncoder().encode(Payload(
            requestHash: requestHash,
            corpusHash: corpusHash,
            offset: offset
        ))
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(
        _ cursor: String,
        requestHash: String,
        corpusHash: String,
        resultCount: Int
    ) throws -> Payload {
        guard !cursor.isEmpty,
              cursor.utf8.count <= LinkQueryLimits.maximumCursorBytes else {
            throw LinkQueryError.invalidCursor
        }
        var base64 = cursor
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.requestHash == requestHash,
              payload.corpusHash.count == 64,
              payload.offset > 0 else {
            throw LinkQueryError.invalidCursor
        }
        guard payload.corpusHash == corpusHash else {
            throw LinkQueryError.staleCursor
        }
        guard payload.offset < resultCount else {
            throw LinkQueryError.invalidCursor
        }
        return payload
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
