/// Shared containment policy for canonical absolute filesystem paths.
///
/// Comparing path components through a separator-qualified prefix prevents a
/// sibling such as `/vault-copy` from being mistaken for a child of `/vault`.
enum CanonicalPathContainment {
    /// Determines whether a canonical path is the root itself or one of its descendants.
    ///
    /// - Parameters:
    ///   - path: Canonical absolute candidate path.
    ///   - rootPath: Canonical absolute directory path.
    /// - Returns: `true` only for the exact root or a separator-delimited descendant.
    static func contains(path: String, within rootPath: String) -> Bool {
        var normalizedRoot = rootPath
        while normalizedRoot.count > 1, normalizedRoot.hasSuffix("/") {
            normalizedRoot.removeLast()
        }

        let descendantPrefix = normalizedRoot == "/"
            ? normalizedRoot
            : normalizedRoot + "/"
        return path == normalizedRoot || path.hasPrefix(descendantPrefix)
    }
}
