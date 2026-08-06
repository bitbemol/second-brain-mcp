import Foundation

/// Validates and resolves file paths, ensuring they never escape the vault root.
/// Stateless; canonicalization may inspect filesystem symlinks but retains no state.
struct PathValidator {
    /// Reports whether an existing component of a relative path is a symlink.
    ///
    /// Inspection stops at the first missing component, which is expected for a
    /// create destination. Every existing parent has been checked by that point.
    static func containsSymbolicLinkComponent(
        relativePath: String,
        root: String,
        fileManager: FileManager = .default
    ) -> Bool {
        var candidate = URL(fileURLWithPath: root)
            .standardized
            .resolvingSymlinksInPath()

        for component in (relativePath as NSString).pathComponents {
            candidate.appendPathComponent(component)
            guard let attributes = try? fileManager.attributesOfItem(
                atPath: candidate.path
            ) else {
                break
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                return true
            }
        }
        return false
    }

    /// Resolve a relative path against the vault root and validate it stays within bounds.
    ///
    /// Steps:
    /// 1. Reject empty paths and absolute paths
    /// 2. Pre-screen for obvious traversal patterns (before filesystem access)
    /// 3. Construct the full path: root + relativePath
    /// 4. Resolve symlinks and canonicalize
    /// 5. Assert the resolved path starts with the resolved root
    ///
    /// - Parameters:
    ///   - relativePath: Caller-controlled path relative to the vault root.
    ///   - root: Canonical vault root.
    ///   - allowedExtensions: Optional lowercase extension allowlist.
    /// - Returns: Canonical absolute path contained within `root`.
    /// - Throws: ``PathValidationError`` when validation or containment fails.
    static func resolve(
        relativePath: String,
        root: String,
        allowedExtensions: Set<String>? = nil
    ) throws -> String {
        // 1. Reject empty paths
        guard !relativePath.isEmpty else {
            throw PathValidationError.emptyPath
        }

        // 2. Reject absolute paths — callers must provide relative paths
        guard !relativePath.hasPrefix("/") else {
            throw PathValidationError.absolutePathNotAllowed(relativePath)
        }

        // 3. Pre-screen: reject paths with traversal patterns before touching the filesystem.
        //    This catches nested URL encoding and Unicode normalization tricks.
        if PathTraversalDetector.containsTraversal(in: relativePath) {
            throw PathValidationError.pathContainsTraversal(relativePath)
        }

        // 4. Construct full path and resolve symlinks
        let rootURL = URL(fileURLWithPath: root).standardized
        let fullURL = rootURL.appendingPathComponent(relativePath).standardized
        let resolvedRoot = rootURL.resolvingSymlinksInPath().path
        let resolvedFull = fullURL.resolvingSymlinksInPath().path

        // 5. Assert canonical containment through the shared separator-aware policy.
        guard CanonicalPathContainment.contains(
            path: resolvedFull,
            within: resolvedRoot
        ) else {
            throw PathValidationError.pathEscapesRoot(relativePath)
        }

        // 6. Post-resolution traversal check — belt and suspenders
        if PathTraversalDetector.containsTraversal(in: resolvedFull) {
            throw PathValidationError.pathEscapesRoot(relativePath)
        }

        // 7. Extension allowlist (if provided)
        if let allowed = allowedExtensions, !allowed.isEmpty {
            let ext = (resolvedFull as NSString).pathExtension.lowercased()
            guard allowed.contains(ext) else {
                throw PathValidationError.invalidExtension(relativePath, allowed: allowed)
            }
        }

        return resolvedFull
    }
}
