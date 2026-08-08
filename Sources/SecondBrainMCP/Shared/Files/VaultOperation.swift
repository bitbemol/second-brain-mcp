/// Transport-neutral operation vocabulary shared by audit and rejection boundaries.
enum VaultOperation: String, CaseIterable, Codable, Equatable, Sendable {
    /// Persist a new first-class file.
    case create
    /// Read a file or reference.
    case read
    /// Replace or transform an existing file.
    case update
    /// Move an existing file into recoverable trash.
    case delete
    /// Atomically rename a complete notes directory subtree.
    case move

    /// Lifts a format-aware file operation into the vault-wide vocabulary.
    init(_ operation: FileCRUDOperation) {
        switch operation {
        case .create: self = .create
        case .read: self = .read
        case .update: self = .update
        case .delete: self = .delete
        }
    }

    /// Returns the corresponding generic file operation when one exists.
    var fileCRUDOperation: FileCRUDOperation? {
        switch self {
        case .create: .create
        case .read: .read
        case .update: .update
        case .delete: .delete
        case .move: nil
        }
    }

    /// Whether the operation can change stored vault content or paths.
    var isMutation: Bool {
        switch self {
        case .create, .update, .delete, .move: true
        case .read: false
        }
    }
}
