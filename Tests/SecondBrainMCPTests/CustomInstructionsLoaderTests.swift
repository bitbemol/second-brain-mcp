import Darwin
import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Custom instruction loading` {
    @Test
    func `Loads a bounded regular UTF-8 file`() throws {
        let vault = try makeVault()
        try Data("  Prefer short notes.\n".utf8).write(
            to: vault.appendingPathComponent("INSTRUCTIONS.md")
        )

        #expect(
            CustomInstructionsLoader.load(vaultPath: vault.path)
                == "Prefer short notes."
        )
    }

    @Test
    func `Rejects an outside-pointing instruction symlink`() throws {
        let vault = try makeVault()
        let outside = vault.deletingLastPathComponent()
            .appendingPathComponent("secret-(UUID().uuidString)")
        try Data("do not disclose".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("INSTRUCTIONS.md"),
            withDestinationURL: outside
        )

        #expect(CustomInstructionsLoader.load(vaultPath: vault.path) == nil)
    }

    @Test
    func `Rejects oversized instruction files`() throws {
        let vault = try makeVault()
        try Data(count: CustomInstructionsLoader.maximumBytes + 1).write(
            to: vault.appendingPathComponent("INSTRUCTIONS.md")
        )

        #expect(CustomInstructionsLoader.load(vaultPath: vault.path) == nil)
    }

    @Test
    func `Rejects a FIFO without blocking`() throws {
        let vault = try makeVault()
        let fifo = vault.appendingPathComponent("INSTRUCTIONS.md")
        #expect(Darwin.mkfifo(fifo.path, 0o600) == 0)

        #expect(CustomInstructionsLoader.load(vaultPath: vault.path) == nil)
    }

    private func makeVault() throws -> URL {
        let vault = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "CustomInstructionsLoaderTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: vault,
            withIntermediateDirectories: true
        )
        return vault
    }
}
