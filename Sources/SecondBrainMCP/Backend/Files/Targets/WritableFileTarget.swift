import Foundation

/// A target that is structurally confined to `notes/`.
///
/// There is no initializer that can produce a writable `references/` target.
struct WritableFileTarget: Sendable {
    /// Canonical absolute filesystem URL under `notes/`.
    let url: URL
    /// Original vault-relative path used for output, recovery, and audit metadata.
    let relativePath: String
    /// Declared concrete format verified against the path extension.
    let format: FileFormat
    let vaultPath: String
    /// Structural vault area guaranteed by this target type.
    var area: VaultArea { .notes }

    private init(
        url: URL,
        relativePath: String,
        format: FileFormat,
        vaultPath: String
    ) {
        self.url = url
        self.relativePath = relativePath
        self.format = format
        self.vaultPath = vaultPath
    }

    /// Resolves a caller-controlled path into a structurally writable target.
    ///
    /// - Parameters:
    ///   - path: Vault-relative path that must be under `notes/`.
    ///   - format: Explicit concrete format declared by the caller.
    ///   - vaultPath: Canonical vault root.
    /// - Returns: A target that cannot represent `references/`.
    /// - Throws: ``FileRoutingError`` or ``PathValidationError``.
    static func resolve(
        path: String,
        format: FileFormat,
        vaultPath: String
    ) throws -> WritableFileTarget {
        guard try VaultArea.resolve(path: path) == .notes else {
            throw FileRoutingError.areaNotWritable(path)
        }
        guard format.accepts(path: path) else {
            throw FileRoutingError.extensionMismatch(path: path, format: format)
        }
        let resolved = try PathValidator.resolve(
            relativePath: path,
            root: vaultPath,
            allowedExtensions: format.extensions
        )

        // Reads may intentionally follow a link that stays inside the vault, but
        // mutations cannot. Besides protecting the read-only references area,
        // rejecting every writable symlink keeps validated and persisted paths bound
        // to the same object. Inspect components explicitly because Foundation
        // cannot canonicalize a symlink parent when the final create target is
        // still absent.
        guard !PathValidator.containsSymbolicLinkComponent(
            relativePath: path,
            root: vaultPath
        ) else {
            throw PathValidationError.symbolicLinkNotAllowed(path)
        }

        let canonicalVault = URL(fileURLWithPath: vaultPath)
            .standardized
            .resolvingSymlinksInPath()
        let expectedURL = canonicalVault
            .appendingPathComponent(path)
            .standardized
        guard resolved == expectedURL.path else {
            throw PathValidationError.symbolicLinkNotAllowed(path)
        }

        let notesRoot = canonicalVault
            .appendingPathComponent(VaultArea.notes.rawValue, isDirectory: true)
            .standardized
            .path
        guard CanonicalPathContainment.contains(path: resolved, within: notesRoot) else {
            throw FileRoutingError.areaNotWritable(path)
        }
        return WritableFileTarget(
            url: URL(fileURLWithPath: resolved),
            relativePath: path,
            format: format,
            vaultPath: vaultPath
        )
    }

    /// Confirms no symlink or area mapping changed after target construction.
    func revalidate() throws {
        let current = try Self.resolve(
            path: relativePath,
            format: format,
            vaultPath: vaultPath
        )
        guard current.url == url else {
            throw PathValidationError.pathChangedSinceValidation(relativePath)
        }
    }
}
