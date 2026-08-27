/// Rejections produced while canonicalizing a caller-controlled vault path.
enum PathValidationError: Error, CustomStringConvertible, CallerSafeError, Sendable {
    /// The relative path is empty.
    case emptyPath
    case emptyComponent

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

    /// Fixed path rules only; associated paths and extension strings remain private.
    var callerSafeDescription: String {
        switch self {
        case .emptyPath:
            "Path must not be empty; provide a vault-relative path including its area."
        case .emptyComponent:
            "Path contains an empty path component; use a single slash between components."
        case .absolutePathNotAllowed:
            "Absolute paths are not allowed; provide a vault-relative path including notes/ or references/."
        case .pathEscapesRoot:
            "Path must remain inside the vault; choose a contained vault-relative path."
        case .invalidExtension:
            "Path extension is not allowed; choose an extension matching the declared format."
        case .pathContainsTraversal:
            "Path contains directory traversal; remove parent-directory components and use a vault-relative path."
        case .symbolicLinkNotAllowed:
            "Writable paths must not contain symbolic links; choose a regular notes/ path."
        case .pathChangedSinceValidation:
            "Path changed after validation; inspect the current path before trying again."
        }
    }

    /// Human-readable path validation failure.
    var description: String {
        switch self {
        case .emptyPath:
            return "Path must not be empty"
        case .emptyComponent:
            return callerSafeDescription
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
