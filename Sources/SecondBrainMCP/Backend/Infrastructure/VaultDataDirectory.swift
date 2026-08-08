import CryptoKit
import Darwin
import Foundation

/// Prepared process-owned storage associated with one managed vault.
///
/// Preparation creates the hashed support directory and may migrate legacy
/// state. Production coordinates that migration through its vault-wide lock.
struct VaultDataDirectory: Sendable {
    /// Vault-specific process-data directory outside the managed vault.
    let rootURL: URL
    /// Append-only audit-log destination inside ``rootURL``.
    let auditLogURL: URL
    /// Persistent advisory-lock files shared by every process for this vault.
    let lockDirectoryURL: URL
    /// Durable successful-mutation receipts used for timeout-safe replay.
    let receiptDirectoryURL: URL
    /// Derived persistent search data that never enters the managed vault.
    let searchIndexDirectoryURL: URL

    private init(rootURL: URL) {
        self.rootURL = rootURL
        self.auditLogURL = rootURL.appendingPathComponent("audit.log")
        self.lockDirectoryURL = rootURL.appendingPathComponent("locks", isDirectory: true)
        self.receiptDirectoryURL = rootURL.appendingPathComponent("receipts", isDirectory: true)
        self.searchIndexDirectoryURL = rootURL.appendingPathComponent(
            "search-index",
            isDirectory: true
        )
    }

    /// Prepares production process storage for one vault.
    ///
    /// - Parameters:
    ///   - vaultPath: Canonical absolute vault root.
    ///   - migrateLegacyData: Whether obsolete vault-local process data may move.
    /// - Returns: Ready process-owned paths for downstream infrastructure.
    /// - Throws: A filesystem error when creation or legacy migration fails.
    static func prepare(
        vaultPath: String,
        migrateLegacyData: Bool = true
    ) throws -> VaultDataDirectory {
        let supportRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SecondBrainMCP")
        return try prepare(
            vaultPath: vaultPath,
            supportRoot: supportRoot,
            migrateLegacyData: migrateLegacyData
        )
    }

    /// Prepares process storage beneath an injected support root.
    ///
    /// This overload keeps migration behavior deterministic and isolated in
    /// tests while production uses the standard Application Support location.
    ///
    /// - Parameters:
    ///   - vaultPath: Absolute vault root whose legacy directory may be migrated.
    ///   - supportRoot: Parent directory for hashed per-vault process data.
    ///   - migrateLegacyData: Whether obsolete vault-local process data may move.
    ///   - fileManager: Filesystem implementation used for preparation.
    /// - Returns: Ready process-owned paths for downstream infrastructure.
    /// - Throws: A filesystem error when creation or legacy migration fails.
    static func prepare(
        vaultPath: String,
        supportRoot: URL,
        migrateLegacyData: Bool = true,
        fileManager: FileManager = .default
    ) throws -> VaultDataDirectory {
        let directory = VaultDataDirectory(
            rootURL: supportRoot.appendingPathComponent(
                hashPath(vaultPath),
                isDirectory: true
            )
        )
        try prepareDirectory(directory.rootURL, fileManager: fileManager)
        try prepareDirectory(directory.lockDirectoryURL, fileManager: fileManager)
        try prepareDirectory(
            directory.lockDirectoryURL.appendingPathComponent("paths", isDirectory: true),
            fileManager: fileManager
        )
        try prepareDirectory(
            directory.lockDirectoryURL.appendingPathComponent("mutations", isDirectory: true),
            fileManager: fileManager
        )
        try prepareDirectory(directory.receiptDirectoryURL, fileManager: fileManager)
        try preparePrivateDirectory(
            directory.searchIndexDirectoryURL,
            fileManager: fileManager
        )
        if migrateLegacyData {
            try directory.migrateLegacyData(
                from: vaultPath,
                fileManager: fileManager
            )
        }
        return directory
    }

    /// Migrates obsolete vault-local process data into this prepared directory.
    ///
    /// Production invokes this method while holding the vault-wide process lock
    /// so simultaneous MCP startups cannot race the compatibility move.
    ///
    /// - Parameters:
    ///   - vaultPath: Canonical managed vault root.
    ///   - fileManager: Filesystem implementation used for migration.
    func migrateLegacyData(
        from vaultPath: String,
        fileManager: FileManager = .default
    ) throws {
        try LegacyVaultDataMigrator.migrate(
            from: URL(fileURLWithPath: vaultPath),
            destinationAuditLog: auditLogURL,
            fileManager: fileManager
        )
    }

    private static func hashPath(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Creates one process-owned directory and refuses symlink substitutions.
    private static func prepareDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// Derived search data may contain extracted vault text, so its directory
    /// must remain private even when an older installation created it loosely.
    private static func preparePrivateDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        try prepareDirectory(url, fileManager: fileManager)
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == geteuid() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard Darwin.chmod(url.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
