/// Rejections produced while canonicalizing a caller-controlled vault path.
enum PathValidationError: Error, CustomStringConvertible, Sendable {
    /// The relative path is empty.
    case emptyPath

    /// The caller supplied an absolute path.
    case absolutePathNotAllowed(String)

    /// Canonical or symlink-resolved content leaves the vault root.
    case pathEscapesRoot(String)

    /// The resolved filename extension is outside the supplied allowlist.
    case invalidExtension(String, allowed: Set<String>)

    /// A relative component explicitly traverses to its parent.
    case pathContainsTraversal(String)

    /// A mutation path contains a symbolic-link component.
    case symbolicLinkNotAllowed(String)

    /// A path resolves differently than when its target value was constructed.
    case pathChangedSinceValidation(String)

    /// Human-readable path validation failure.
    var description: String {
        switch self {
        case .emptyPath:
            return "Path must not be empty"
        case .absolutePathNotAllowed(let path):
            return "Absolute paths are not allowed: \(path)"
        case .pathEscapesRoot(let path):
            return "Path escapes vault root: \(path)"
        case .invalidExtension(let path, let allowed):
            return "File extension not allowed for '\(path)'. Allowed: \(allowed.sorted().joined(separator: ", "))"
        case .pathContainsTraversal(let path):
            return "Path contains directory traversal: \(path)"
        case .symbolicLinkNotAllowed(let path):
            return "Writable paths must not contain symbolic links: \(path)"
        case .pathChangedSinceValidation(let path):
            return "Path changed after validation: \(path)"
        }
    }
}
