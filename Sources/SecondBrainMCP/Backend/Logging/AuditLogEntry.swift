/// One escaped, line-oriented record written to the backend audit log.
struct AuditLogEntry: Sendable {
    /// Per-field character ceiling that prevents one request from dominating a log.
    private static let maximumFieldCharacters = 2_048
    /// ISO-8601 timestamp supplied by the logger.
    let timestamp: String

    /// Transport-neutral vault operation being recorded.
    let operation: VaultOperation

    /// Vault area used to distinguish ordinary and reference reads.
    let area: VaultArea

    /// Optional caller-controlled path.
    let path: String?

    /// Optional handler or rejection context.
    let details: String?

    /// Creates an immutable audit record before line serialization.
    ///
    /// - Parameters:
    ///   - timestamp: Preformatted ISO-8601 timestamp.
    ///   - operation: Vault operation being recorded.
    ///   - area: Vault area associated with the operation.
    ///   - path: Optional caller-controlled path.
    ///   - details: Optional handler or rejection context.
    init(
        timestamp: String,
        operation: VaultOperation,
        area: VaultArea,
        path: String?,
        details: String?
    ) {
        self.timestamp = timestamp
        self.operation = operation
        self.area = area
        self.path = path
        self.details = details
    }

    /// Serialized record containing exactly one trailing physical newline.
    ///
    /// Backslashes, field separators, tabs, and newline characters in untrusted
    /// fields are escaped so they cannot create forged records or columns.
    var line: String {
        let storedOperation = StoredOperation(operation: operation, area: area)
        var value = "\(timestamp) | \(storedOperation.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
        if let path {
            value += " | \(Self.escape(path))"
        }
        if let details {
            value += " | \(Self.escape(details))"
        }
        return value + "\n"
    }

    private static func escape(_ value: String) -> String {
        var escaped = ""
        let truncated = value.count > maximumFieldCharacters
        let bounded = value.prefix(maximumFieldCharacters)
        escaped.reserveCapacity(min(value.utf8.count, maximumFieldCharacters * 4))

        for scalar in bounded.unicodeScalars {
            switch scalar.value {
            case 0x5C: escaped += "\\\\"
            case 0x7C: escaped += "\\|"
            case 0x09: escaped += "\\t"
            case 0x0A: escaped += "\\n"
            case 0x0D: escaped += "\\r"
            case 0x85, 0x2028, 0x2029: escaped += "\\n"
            default: escaped += String(scalar)
            }
        }
        if truncated { escaped += "…" }
        return escaped
    }

    private enum StoredOperation: String {
        case read = "READ"
        case create = "CREATE"
        case update = "UPDATE"
        case delete = "DELETE"
        case move = "MOVE"
        case readReference = "READ_REF"

        init(operation: VaultOperation, area: VaultArea) {
            switch operation {
            case .create: self = .create
            case .read: self = area == .references ? .readReference : .read
            case .update: self = .update
            case .delete: self = .delete
            case .move: self = .move
            }
        }
    }
}
