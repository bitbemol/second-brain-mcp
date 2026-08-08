import Foundation

/// Canonical JSON representations shared by search budgeting and MCP mapping.
///
/// The complete response uses the human-readable compatibility shape emitted
/// by the MCP tool. Result-array sizing stays compact because it is an internal
/// admission budget, but uses the same keys and escaping rules everywhere.
enum VaultSearchJSONEncoding {
    /// Encodes one complete compatibility response with stable wire formatting.
    static func responseData(_ response: VaultSearchResponse) throws -> Data {
        try encoder(prettyPrinted: true).encode(response)
    }

    /// Encodes one complete compatibility response as UTF-8 JSON text.
    static func responseText(_ response: VaultSearchResponse) throws -> String {
        String(decoding: try responseData(response), as: UTF8.self)
    }

    /// Returns the exact UTF-8 byte count of ``responseText(_:)``.
    static func responseByteCount(_ response: VaultSearchResponse) throws -> Int {
        try responseData(response).count
    }

    /// Encodes only the result array using the canonical compact budget shape.
    static func resultsData(_ results: [VaultSearchResult]) throws -> Data {
        try encoder(prettyPrinted: false).encode(results)
    }

    /// Returns the exact byte count used for result-array admission.
    static func resultsByteCount(_ results: [VaultSearchResult]) throws -> Int {
        try resultsData(results).count
    }

    private static func encoder(prettyPrinted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted { encoder.outputFormatting.insert(.prettyPrinted) }
        return encoder
    }
}
