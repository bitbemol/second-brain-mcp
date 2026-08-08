import CryptoKit
import Foundation

/// Creates request- and corpus-bound opaque offsets for deterministic pagination.
enum SearchCursorCodec {
    struct Decoded: Sendable {
        let offset: Int
        let corpusFingerprint: String
    }

    private static let version = "v2"

    /// Encodes an offset plus request/corpus fingerprints as URL-safe Base64.
    static func encode(
        offset: Int,
        fingerprint: String,
        corpusFingerprint: String
    ) -> String {
        Data("\(version):\(offset):\(fingerprint):\(corpusFingerprint)".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Validates and decodes a cursor for the expected request fingerprint.
    static func decode(_ cursor: String, fingerprint: String) throws -> Decoded {
        guard cursor.utf8.count <= SearchRequestLimits.maximumCursorBytes else {
            throw VaultSearchRequestError.invalidCursor
        }
        var base64 = cursor.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {
            throw VaultSearchRequestError.invalidCursor
        }
        let parts = decoded.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == Substring(version),
              let offset = Int(parts[1]),
              offset >= 0,
              parts[2] == Substring(fingerprint),
              parts[3].count == 64,
              parts[3].allSatisfy({ $0.isHexDigit }) else {
            throw VaultSearchRequestError.invalidCursor
        }
        return Decoded(offset: offset, corpusFingerprint: String(parts[3]))
    }

    /// Hashes every request option that can change result membership or order.
    static func fingerprint(
        request: VaultSearchRequest,
        fields: Set<SearchField>,
        formats: Set<FileFormat>,
        areas: Set<VaultArea>,
        scopePrefixes: [String]
    ) -> String {
        let input = [
            request.query,
            request.strategy.rawValue,
            fields.map(\.rawValue).sorted().joined(separator: ","),
            formats.map(\.rawValue).sorted().joined(separator: ","),
            areas.map(\.rawValue).sorted().joined(separator: ","),
            scopePrefixes.joined(separator: ","),
            String(request.minimumRelevance),
            String(request.maxHitsPerFile),
        ].joined(separator: "\u{001F}")
        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
