import CryptoKit
import Foundation

/// Stable digest of one complete mutation request excluding transport timing.
struct MutationRequestFingerprint: Hashable, Sendable, Codable {
    /// Lowercase SHA-256 digest of sorted-key request JSON.
    let rawValue: String

    /// Computes a deterministic fingerprint for a Codable request value.
    static func make<Request: Encodable>(
        operation: FileCRUDOperation,
        request: Request
    ) throws -> MutationRequestFingerprint {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let requestData = try encoder.encode(request)
        var input = Data(operation.rawValue.utf8)
        input.append(0)
        input.append(requestData)
        let digest = SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
        return MutationRequestFingerprint(rawValue: digest)
    }
}
