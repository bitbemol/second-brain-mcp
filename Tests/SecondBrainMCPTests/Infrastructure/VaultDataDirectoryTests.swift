import Darwin
import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Vault process-data directory` {
    @Test
    func `Preparation is idempotent and creates private infrastructure`() throws {
        let roots = try makeRoots()

        let prepared = try VaultDataDirectory.prepare(
            vaultPath: roots.vault.path,
            supportRoot: roots.support
        )
        let repeated = try VaultDataDirectory.prepare(
            vaultPath: roots.vault.path,
            supportRoot: roots.support
        )

        #expect(prepared.rootURL == repeated.rootURL)
        #expect(FileManager.default.fileExists(atPath: prepared.lockDirectoryURL.path))
        #expect(FileManager.default.fileExists(atPath: prepared.searchIndexDirectoryURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: prepared.rootURL.appendingPathComponent("audit.log").path
        ))

        var searchIndexStat = stat()
        #expect(Darwin.lstat(prepared.searchIndexDirectoryURL.path, &searchIndexStat) == 0)
        #expect(searchIndexStat.st_mode & S_IFMT == S_IFDIR)
        #expect(searchIndexStat.st_uid == geteuid())
        #expect(searchIndexStat.st_mode & 0o077 == 0)
    }

    @Test
    func `Preparation leaves obsolete vault-local data untouched`() throws {
        let roots = try makeRoots()
        let legacyRoot = roots.vault.appendingPathComponent(".secondbrain-mcp")
        try FileManager.default.createDirectory(
            at: legacyRoot.appendingPathComponent("cache"),
            withIntermediateDirectories: true
        )
        let legacyAudit = legacyRoot.appendingPathComponent("audit.log")
        try Data("old audit".utf8).write(to: legacyAudit)

        _ = try VaultDataDirectory.prepare(
            vaultPath: roots.vault.path,
            supportRoot: roots.support
        )

        #expect(try String(contentsOf: legacyAudit, encoding: .utf8) == "old audit")
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
