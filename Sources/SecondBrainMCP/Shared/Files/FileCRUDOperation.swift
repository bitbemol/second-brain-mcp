/// Format-aware operations supported by the generic file boundary.
enum FileCRUDOperation: String, CaseIterable, Codable, Equatable, Sendable {
    /// Persist a new file at an unused destination.
    case create
    /// Return a format-specific representation of an existing file.
    case read
    /// Replace or transform the content of an existing file.
    case update
    /// Move an existing file into the vault trash.
    case delete
    /// Whether the operation can change stored vault content.
    var isMutation: Bool {
        switch self {
        case .create, .update, .delete:
            true
        case .read:
            false
        }
    }
}
