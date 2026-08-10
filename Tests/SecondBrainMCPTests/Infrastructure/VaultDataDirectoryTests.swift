import Foundation
import Darwin
import Testing
@testable import second_brain_mcp

@Suite
struct `Vault process-data directory` {
    @Test
    func `Migrates known legacy data without deleting unknown files`() throws {
        let roots = try makeRoots()
        let legacyRoot = roots.vault.appendingPathComponent(".secondbrain-mcp")
        try FileManager.default.createDirectory(
            at: legacyRoot.appendingPathComponent("cache"),
            withIntermediateDirectories: true
        )
        try Data("old audit".utf8).write(
            to: legacyRoot.appendingPathComponent("audit.log")
        )
        try Data("lock".utf8).write(
            to: legacyRoot.appendingPathComponent("extraction.lock")
        )
        try Data("preserve".utf8).write(
            to: legacyRoot.appendingPathComponent("unknown.data")
        )

        let prepared = try VaultDataDirectory.prepare(
            vaultPath: roots.vault.path,
            supportRoot: roots.support
        )
        let repeated = try VaultDataDirectory.prepare(
            vaultPath: roots.vault.path,
            supportRoot: roots.support
        )

        #expect(prepared.rootURL == repeated.rootURL)
        var searchIndexStat = stat()
        #expect(Darwin.lstat(prepared.searchIndexDirectoryURL.path, &searchIndexStat) == 0)
        #expect(searchIndexStat.st_mode & S_IFMT == S_IFDIR)
        #expect(searchIndexStat.st_uid == geteuid())
        #expect(searchIndexStat.st_mode & 0o077 == 0)
        #expect(try String(contentsOf: prepared.auditLogURL, encoding: .utf8) == "old audit")
        #expect(!FileManager.default.fileExists(
            atPath: legacyRoot.appendingPathComponent("cache").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: legacyRoot.appendingPathComponent("extraction.lock").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: legacyRoot.appendingPathComponent("unknown.data").path
        ))
    }

    @Test
    func `Removes an empty legacy directory after migration`() throws {
        let roots = try makeRoots()
        let legacyRoot = roots.vault.appendingPathComponent(".secondbrain-mcp")
        try FileManager.default.createDirectory(
            at: legacyRoot,
            withIntermediateDirectories: true
        )
        try Data("old audit".utf8).write(
            to: legacyRoot.appendingPathComponent("audit.log")
        )

        let prepared = try VaultDataDirectory.prepare(
            vaultPath: roots.vault.path,
            supportRoot: roots.support
        )

        #expect(FileManager.default.fileExists(atPath: prepared.rootURL.path))
        #expect(FileManager.default.fileExists(atPath: prepared.auditLogURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyRoot.path))
    }

    @Test
    func `Migration never follows a symlinked legacy root`() throws {
        let roots = try makeRoots()
        let external = roots.vault
            .deletingLastPathComponent()
            .appendingPathComponent("external")
        let externalCache = external.appendingPathComponent("cache")
        try FileManager.default.createDirectory(
            at: externalCache,
            withIntermediateDirectories: true
        )
        let marker = externalCache.appendingPathComponent("keep.txt")
        try Data("preserve".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(
            at: roots.vault.appendingPathComponent(".secondbrain-mcp"),
            withDestinationURL: external
        )

        _ = try VaultDataDirectory.prepare(
            vaultPath: roots.vault.path,
            supportRoot: roots.support
        )

        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(FileManager.default.fileExists(
            atPath: roots.vault.appendingPathComponent(".secondbrain-mcp").path
        ))
    }

    @Test
    func `Migration preserves symlinked known entries`() throws {
        let roots = try makeRoots()
        let legacyRoot = roots.vault.appendingPathComponent(".secondbrain-mcp")
        let external = roots.vault
            .deletingLastPathComponent()
            .appendingPathComponent("external-cache")
        try FileManager.default.createDirectory(
            at: legacyRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: true
        )
        let marker = external.appendingPathComponent("keep.txt")
        try Data("preserve".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(
            at: legacyRoot.appendingPathComponent("cache"),
            withDestinationURL: external
        )

        _ = try VaultDataDirectory.prepare(
            vaultPath: roots.vault.path,
            supportRoot: roots.support
        )

        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(FileManager.default.fileExists(
            atPath: legacyRoot.appendingPathComponent("cache").path
        ))
    }

    @Test
    func `Preparation surfaces filesystem failures`() throws {
        let roots = try makeRoots()
        let blockingFile = roots.support.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(
            at: roots.support,
            withIntermediateDirectories: true
        )
        try Data("blocking".utf8).write(to: blockingFile)

        do {
            _ = try VaultDataDirectory.prepare(
                vaultPath: roots.vault.path,
                supportRoot: blockingFile
            )
            Issue.record("Expected process-data preparation to fail")
        } catch {
            // The failure is the contract: bootstrap must not silently continue.
        }
    }

    @Test
    func `The vault-wide lock serializes simultaneous legacy migration`() async throws {
        let roots = try makeRoots()
        let legacyRoot = roots.vault.appendingPathComponent(".secondbrain-mcp")
        try FileManager.default.createDirectory(
            at: legacyRoot.appendingPathComponent("cache"),
            withIntermediateDirectories: true
        )
        try Data("old audit".utf8).write(
            to: legacyRoot.appendingPathComponent("audit.log")
        )
        let prepared = try VaultDataDirectory.prepare(
            vaultPath: roots.vault.path,
            supportRoot: roots.support,
            migrateLegacyData: false
        )
        let lock = POSIXAdvisoryFileLock(
            url: prepared.lockDirectoryURL
                .appendingPathComponent("vault-versioning.lock"),
            retryNanoseconds: 1_000_000
        )

        async let first: Void = lock.withLock(.exclusive) {
            try prepared.migrateLegacyData(from: roots.vault.path)
        }
        async let second: Void = lock.withLock(.exclusive) {
            try prepared.migrateLegacyData(from: roots.vault.path)
        }
        _ = try await (first, second)

        #expect(
            try String(contentsOf: prepared.auditLogURL, encoding: .utf8)
                == "old audit"
        )
        #expect(!FileManager.default.fileExists(atPath: legacyRoot.path))
    }

    private func makeRoots() throws -> (vault: URL, support: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VaultDataDirectoryTests-\(UUID().uuidString)")
        let vault = base.appendingPathComponent("vault")
        try FileManager.default.createDirectory(
            at: vault,
            withIntermediateDirectories: true
        )
        return (vault, base.appendingPathComponent("support"))
    }
}
