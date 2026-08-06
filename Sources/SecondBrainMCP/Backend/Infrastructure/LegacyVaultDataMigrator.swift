import Foundation

/// Migrates known data from the obsolete vault-local process directory.
///
/// Unknown legacy files are deliberately preserved. This compatibility boundary
/// owns every historical filename so current process-data types remain independent
/// of the retired `.secondbrain-mcp` layout.
enum LegacyVaultDataMigrator {
    /// Preserves the legacy audit log and removes known obsolete internals.
    ///
    /// The legacy root is removed only when no unknown files remain.
    ///
    /// - Parameters:
    ///   - vaultRoot: Managed vault that may contain legacy process data.
    ///   - destinationAuditLog: Current process-owned audit-log destination.
    ///   - fileManager: Filesystem implementation used for migration.
    /// - Throws: A filesystem error while moving or removing known data.
    static func migrate(
        from vaultRoot: URL,
        destinationAuditLog: URL,
        fileManager: FileManager = .default
    ) throws {
        let legacyRoot = vaultRoot.appendingPathComponent(".secondbrain-mcp")
        guard fileType(at: legacyRoot, fileManager: fileManager) == .typeDirectory else {
            // Unknown files and symlinks are user-owned compatibility artifacts.
            // Following a symlink here would let migration delete outside the vault.
            return
        }

        let legacyAuditLog = legacyRoot.appendingPathComponent("audit.log")
        if fileType(at: legacyAuditLog, fileManager: fileManager) == .typeRegular,
           !fileManager.fileExists(atPath: destinationAuditLog.path) {
            try fileManager.moveItem(
                at: legacyAuditLog,
                to: destinationAuditLog
            )
        }

        try removeIfPresent(
            legacyRoot.appendingPathComponent("cache"),
            fileManager: fileManager
        )
        try removeIfPresent(
            legacyRoot.appendingPathComponent("extraction.lock"),
            fileManager: fileManager
        )

        let remaining = try fileManager.contentsOfDirectory(atPath: legacyRoot.path)
        if remaining.isEmpty {
            try fileManager.removeItem(at: legacyRoot)
        }
    }

    /// Removes one known legacy path when it still exists.
    private static func removeIfPresent(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        guard let type = fileType(at: url, fileManager: fileManager),
              type != .typeSymbolicLink else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    /// Reads the directory-entry kind without following a final symbolic link.
    private static func fileType(
        at url: URL,
        fileManager: FileManager
    ) -> FileAttributeType? {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType
    }
}
