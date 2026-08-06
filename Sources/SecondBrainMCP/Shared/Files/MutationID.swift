import Foundation

/// Caller-generated identity that makes one mutation safely replayable.
///
/// A client must reuse the same identifier only when retrying the exact same
/// create, update, or delete request after a timeout or lost response.
struct MutationID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Canonical lowercase UUID representation used on the wire and on disk.
    let rawValue: String

    /// Parses and normalizes a UUID mutation identity.
    init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.rawValue = uuid.uuidString.lowercased()
    }

    /// Creates a fresh mutation identity.
    init() {
        self.rawValue = UUID().uuidString.lowercased()
    }

    /// Canonical mutation identifier used in diagnostics and Git metadata.
    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let identifier = MutationID(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid mutation UUID"
            )
        }
        self = identifier
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
