/// Opaque identity of the exact bytes stored for one mutable vault file.
///
/// Clients receive this value from `read_file` and must return it as
/// `expected_revision` when updating or deleting a note. The representation is
/// intentionally content-derived rather than timestamp-derived so equal bytes
/// always have equal revisions across processes.
struct FileRevision: Hashable, Sendable, Codable, CustomStringConvertible {
    private static let prefix = "sha256:"
    private static let hexadecimal = Set("0123456789abcdef")

    /// Stable wire representation: `sha256:` followed by 64 lowercase hex digits.
    let rawValue: String

    /// Parses and validates a caller-supplied revision token.
    init?(rawValue: String) {
        guard rawValue.hasPrefix(Self.prefix) else { return nil }
        let digest = rawValue.dropFirst(Self.prefix.count)
        guard digest.count == 64,
              digest.allSatisfy({ Self.hexadecimal.contains($0) }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Creates a revision from a trusted lowercase SHA-256 digest.
    init(validatedSHA256Hex digest: String) {
        precondition(
            digest.count == 64
                && digest.allSatisfy { Self.hexadecimal.contains($0) }
        )
        self.rawValue = Self.prefix + digest
    }

    /// Revision text used in diagnostics and MCP structured results.
    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let revision = FileRevision(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid file revision"
            )
        }
        self = revision
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
