import CryptoKit
import Foundation

/// Prepared process-owned storage associated with one managed vault.
///
/// Construction creates the hashed support directory and coordinates legacy
/// migration before exposing usable paths to downstream infrastructure.
struct VaultDataDirectory: Sendable {
    /// Vault-specific process-data directory outside the managed vault.
    let rootURL: URL
    /// Append-only audit-log destination inside ``rootURL``.
    let auditLogURL: URL

    private init(rootURL: URL) {
        self.rootURL = rootURL
        self.auditLogURL = rootURL.appendingPathComponent("audit.log")
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
        try fileManager.createDirectory(
            at: directory.rootURL,
            withIntermediateDirectories: true
        )
        if migrateLegacyData {
            try LegacyVaultDataMigrator.migrate(
                from: URL(fileURLWithPath: vaultPath),
                destinationAuditLog: directory.auditLogURL,
                fileManager: fileManager
            )
        }
        return directory
    }

    private static func hashPath(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
