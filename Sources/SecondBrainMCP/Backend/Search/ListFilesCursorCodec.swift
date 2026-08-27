import CryptoKit
import Foundation

enum ListFilesCursorCodec {
    struct Payload: Codable, Sendable {
        let requestHash: String
        let corpusHash: String
        let lastPath: String
    }

    private struct Criteria: Codable {
        let area: VaultArea
        let directory: String?
        let recursive: Bool
        let formats: [FileFormat]
    }

    static func requestHash(_ request: ListFilesRequest) throws -> String {
        let criteria = Criteria(
            area: request.area,
            directory: request.directory,
            recursive: request.recursive,
            formats: request.formats
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(criteria))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func encode(
        requestHash: String,
        corpusHash: String,
        lastPath: String
    ) throws -> String {
        try webSafe(JSONEncoder().encode(Payload(
            requestHash: requestHash,
            corpusHash: corpusHash,
            lastPath: lastPath
        )))
    }

    static func decode(
        _ cursor: String,
        requestHash: String
    ) throws -> Payload {
        guard !cursor.isEmpty,
              cursor.utf8.count <= FileListingRequestLimits.maximumCursorBytes,
              cursor.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else {
            throw FileListingError.invalidCursor
        }
        var base64 = cursor
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              webSafe(data) == cursor,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.requestHash == requestHash,
              payload.corpusHash.count == 64,
              payload.corpusHash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              !payload.lastPath.isEmpty else {
            throw FileListingError.invalidCursor
        }
        return payload
    }

    private static func webSafe(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
