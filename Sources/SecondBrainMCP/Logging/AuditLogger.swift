import Foundation

/// Append-only structured log of every operation.
/// Actor because concurrent writes to the log file must be serialized.
actor AuditLogger {

    private let logPath: String

    init(vaultPath: String) {
        self.logPath = DataPaths.auditLog(vaultPath: vaultPath)

        // Ensure directory exists
        DataPaths.ensureRootExists(vaultPath: vaultPath)
    }

    enum Operation: String {
        case read = "READ"
        case create = "CREATE"
        case update = "UPDATE"
        case delete = "DELETE"
        case move = "MOVE"
        case search = "SEARCH"
        case readRef = "READ_REF"
        case searchRef = "SEARCH_REF"
        case listRef = "LIST_REF"
        case metadataRef = "META_REF"

        /// True for operations that mutate the vault. Used to enforce `--read-only`
        /// at dispatch — otherwise read-only only *hides* write tools from
        /// ListTools, and a client could still invoke one by name.
        var isWrite: Bool {
            switch self {
            case .create, .update, .delete, .move:
                return true
            case .read, .search, .readRef, .searchRef, .listRef, .metadataRef:
                return false
            }
        }
    }

    /// Log an operation with optional details.
    func log(operation: Operation, path: String? = nil, details: String? = nil) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())

        var entry = "\(timestamp) | \(operation.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
        if let path {
            entry += " | \(path)"
        }
        if let details {
            entry += " | \(details)"
        }
        entry += "\n"

        // Append to log file
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }
}
