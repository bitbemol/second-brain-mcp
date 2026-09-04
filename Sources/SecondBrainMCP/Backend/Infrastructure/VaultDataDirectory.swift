import CryptoKit
import Darwin
import Foundation

/// Prepared process-owned storage associated with one managed vault.
///
/// Preparation creates the hashed support directory and its private infrastructure.
struct VaultDataDirectory: Sendable {
    /// Vault-specific process-data directory outside the managed vault.
    let rootURL: URL
    /// Persistent advisory-lock files shared by every process for this vault.
    let lockDirectoryURL: URL
    /// Derived persistent search data that never enters the managed vault.
    let searchIndexDirectoryURL: URL
    /// Product-owned bare repository containing recoverable note snapshots.
    let snapshotRepositoryURL: URL
    /// Private transaction indexes used only while publishing one snapshot.
    let snapshotWorkspaceDirectoryURL: URL

    private init(rootURL: URL) {
        self.rootURL = rootURL
        self.lockDirectoryURL = rootURL.appendingPathComponent("locks", isDirectory: true)
        self.searchIndexDirectoryURL = rootURL.appendingPathComponent(
            "search-index",
            isDirectory: true
        )
        self.snapshotRepositoryURL = rootURL.appendingPathComponent(
            "git-snapshots-v1.git",
            isDirectory: true
        )
        self.snapshotWorkspaceDirectoryURL = rootURL.appendingPathComponent(
            "git-snapshot-workspaces-v1",
            isDirectory: true
        )
    }

    /// Prepares production process storage for one vault.
    ///
    /// - Parameters:
    ///   - vaultPath: Canonical absolute vault root.
    /// - Returns: Ready process-owned paths for downstream infrastructure.
    /// - Throws: A filesystem error when directory creation fails.
    static func prepare(vaultPath: String) throws -> VaultDataDirectory {
        let supportRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SecondBrainMCP")
        return try prepare(
            vaultPath: vaultPath,
            supportRoot: supportRoot
        )
    }

    /// Prepares process storage beneath an injected support root.
    ///
    /// This overload keeps process storage deterministic and isolated in tests
    /// while production uses the standard Application Support location.
    ///
    /// - Parameters:
    ///   - vaultPath: Absolute vault root used to derive stable process storage.
    ///   - supportRoot: Parent directory for hashed per-vault process data.
    ///   - fileManager: Filesystem implementation used for preparation.
    /// - Returns: Ready process-owned paths for downstream infrastructure.
    /// - Throws: A filesystem error when directory creation fails.
    static func prepare(
        vaultPath: String,
        supportRoot: URL,
        fileManager: FileManager = .default
    ) throws -> VaultDataDirectory {
        let directory = VaultDataDirectory(
            rootURL: supportRoot.appendingPathComponent(
                hashPath(vaultPath),
                isDirectory: true
            )
        )
        try preparePrivateDirectory(directory.rootURL, fileManager: fileManager)
        try preparePrivateDirectory(directory.lockDirectoryURL, fileManager: fileManager)
        try preparePrivateDirectory(
            directory.searchIndexDirectoryURL,
            fileManager: fileManager
        )
        try validatePrivateDirectoryIfPresent(directory.snapshotRepositoryURL)
        try preparePrivateDirectory(
            directory.snapshotWorkspaceDirectoryURL,
            fileManager: fileManager
        )
        return directory
    }

    private static func hashPath(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Process data can contain derived or snapshotted vault bytes. Refuse a
    /// symlink substitution, require current-user ownership, and repair older
    /// installations that created a directory with broader permissions.
    private static func preparePrivateDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        var value = stat()
        if Darwin.lstat(url.path, &value) != 0 {
            guard errno == ENOENT else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard Darwin.lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == geteuid() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard Darwin.chmod(url.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// Read-only bootstrap must not initialize Git, but an existing durable
    /// repository still has to satisfy the same private-storage boundary.
    private static func validatePrivateDirectoryIfPresent(_ url: URL) throws {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else {
            guard errno == ENOENT else { throw CocoaError(.fileWriteNoPermission) }
            return
        }
        guard value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == geteuid(),
              Darwin.chmod(url.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
