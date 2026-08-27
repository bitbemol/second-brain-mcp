import CryptoKit
import Foundation

/// Fixed-size graph continuation identities; request validation precedes any scan.
enum LinkQueryCursorCodec {
    struct Payload: Codable, Sendable {
        let version: Int
        let requestHash: String
        let corpusHash: String
        let offset: Int
        let anchorHash: String
    }

    private struct Criteria: Codable {
        let direction: LinkQueryDirection
        let target: String
        let fromPath: String?
        let groupBy: LinkQueryGrouping?
        let sourcePath: String?
    }

    static func requestHash(_ request: LinkQueryRequest) throws -> String {
        try hash(Criteria(
            direction: request.direction, target: request.target, fromPath: request.fromPath,
            groupBy: request.direction == .backlinks ? (request.groupBy ?? .source) : nil,
            sourcePath: request.sourcePath
        ))
    }

    static func anchorHash(_ result: LinkQueryResult) throws -> String {
        try hash(result)
    }

    static func encode(
        requestHash: String, corpusHash: String, offset: Int, anchorHash: String
    ) throws -> String {
        let data = try JSONEncoder().encode(Payload(
            version: 2, requestHash: requestHash, corpusHash: corpusHash,
            offset: offset, anchorHash: anchorHash
        ))
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard encoded.utf8.count <= LinkQueryLimits.maximumCursorBytes else {
            throw LinkQueryError.invalidCursor
        }
        return encoded
    }

    static func decode(_ cursor: String, requestHash: String) throws -> Payload {
        guard !cursor.isEmpty, cursor.utf8.count <= LinkQueryLimits.maximumCursorBytes else {
            throw LinkQueryError.invalidCursor
        }
        var base64 = cursor.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 2, payload.requestHash == requestHash,
              isDigest(payload.corpusHash), isDigest(payload.anchorHash),
              payload.offset > 0,
              payload.offset <= LinkQueryExecutionLimits.maximumResolutionCandidates else {
            throw LinkQueryError.invalidCursor
        }
        return payload
    }

    private static func hash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
