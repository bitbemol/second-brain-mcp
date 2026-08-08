/// Operations recorded by the vault file and directory boundaries.
enum FileCRUDOperation: String, CaseIterable, Codable, Equatable, Sendable {
    /// Persist a new file at an unused destination.
    case create
    /// Return a format-specific representation of an existing file.
    case read
    /// Replace or transform the content of an existing file.
    case update
    /// Move an existing file into the vault trash.
    case delete
    /// Atomically rename a complete notes directory subtree.
    case move

    /// Whether the operation can change stored vault content.
    var isMutation: Bool {
        switch self {
        case .create, .update, .delete, .move:
            true
        case .read:
            false
        }
    }
}
