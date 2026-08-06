import Foundation

/// Canonical, extension-checked target that may belong to either vault area.
struct ReadableFileTarget: Sendable {
    /// Canonical absolute filesystem URL.
    let url: URL
    /// Original vault-relative path used for output and Git operations.
    let relativePath: String
    /// Declared concrete format verified against the path extension.
    let format: FileFormat
    /// Structural vault area derived from the path prefix.
    let area: VaultArea
    private let vaultPath: String

    fileprivate init(
        url: URL,
        relativePath: String,
        format: FileFormat,
        area: VaultArea,
        vaultPath: String
    ) {
        self.url = url
        self.relativePath = relativePath
        self.format = format
        self.area = area
        self.vaultPath = vaultPath
    }

    /// Resolves and validates a caller-controlled readable path.
    ///
    /// - Parameters:
    ///   - path: Vault-relative path under `notes/` or `references/`.
    ///   - format: Explicit concrete format declared by the caller.
    ///   - vaultPath: Canonical vault root.
    /// - Returns: A path- and extension-validated target.
    /// - Throws: ``FileRoutingError`` or ``PathValidationError``.
    static func resolve(
        path: String,
        format: FileFormat,
        vaultPath: String
    ) throws -> ReadableFileTarget {
        let area = try VaultArea.resolve(path: path)
        guard format.accepts(path: path) else {
            throw FileRoutingError.extensionMismatch(path: path, format: format)
        }
        let resolved = try PathValidator.resolve(
            relativePath: path,
            root: vaultPath,
            allowedExtensions: format.extensions
        )
        return ReadableFileTarget(
            url: URL(fileURLWithPath: resolved),
            relativePath: path,
            format: format,
            area: area,
            vaultPath: vaultPath
        )
    }

    /// Confirms the caller path still resolves to the originally approved URL.
    func revalidate() throws {
        let current = try PathValidator.resolve(
            relativePath: relativePath,
            root: vaultPath,
            allowedExtensions: format.extensions
        )
        guard current == url.path else {
            throw PathValidationError.pathChangedSinceValidation(relativePath)
        }
    }
}

extension WritableFileTarget {
    /// Readable view of the same validated `notes/` target.
    var readable: ReadableFileTarget {
        ReadableFileTarget(
            url: url,
            relativePath: relativePath,
            format: format,
            area: area,
            vaultPath: vaultPath
        )
    }
}
