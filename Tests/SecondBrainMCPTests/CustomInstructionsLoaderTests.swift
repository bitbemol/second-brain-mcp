import Darwin
import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Custom instruction loading")
struct CustomInstructionsLoaderTests {
    @Test("Loads a bounded regular UTF-8 file")
    func loadsRegularFile() throws {
        let vault = try makeVault()
        try Data("  Prefer short notes.\n".utf8).write(
            to: vault.appendingPathComponent("INSTRUCTIONS.md")
        )

        #expect(
            CustomInstructionsLoader.load(vaultPath: vault.path)
                == "Prefer short notes."
        )
    }

    @Test("Rejects an outside-pointing instruction symlink")
    func rejectsSymlink() throws {
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

    @Test("Rejects oversized instruction files")
    func rejectsOversizedFile() throws {
        let vault = try makeVault()
        try Data(count: CustomInstructionsLoader.maximumBytes + 1).write(
            to: vault.appendingPathComponent("INSTRUCTIONS.md")
        )

        #expect(CustomInstructionsLoader.load(vaultPath: vault.path) == nil)
    }

    @Test("Rejects a FIFO without blocking")
    func rejectsFIFO() throws {
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
