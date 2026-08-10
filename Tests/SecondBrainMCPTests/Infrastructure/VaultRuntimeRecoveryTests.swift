import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct VaultRuntimeRecoveryTests {
    @Test
    func writableStartupSnapshotsPendingNoteChanges() async throws {
        let root = try makeVault()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        try Data("pending".utf8).write(
            to: URL(fileURLWithPath: root)
                .appendingPathComponent("notes/pending.md"),
            options: .atomic
        )

        _ = try await VaultRuntime.bootstrap(vaultPath: root)

        #expect(
            try runGit(["status", "--porcelain", "--", "notes"], at: root)
                .isEmpty
        )
        #expect(
            try runGit(["log", "-1", "--pretty=%s"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "Vault snapshot"
        )
    }

    @Test
    func startupLeavesReferenceContentOutsideHistory() async throws {
        let root = try makeVault()
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        try Data("large immutable reference".utf8).write(
            to: URL(fileURLWithPath: root)
                .appendingPathComponent("references/book.txt"),
            options: .atomic
        )
        try Data("tracked note".utf8).write(
            to: URL(fileURLWithPath: root)
                .appendingPathComponent("notes/note.md"),
            options: .atomic
        )
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }

        _ = try await VaultRuntime.bootstrap(vaultPath: root)

        #expect(
            try runGit(
                ["ls-tree", "-r", "--name-only", "HEAD", "--", "references"],
                at: root
            ).isEmpty
        )
    }

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory()
            + "VaultRuntimeRecoveryTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        return root
    }

    private func productionDataDirectory(for root: String) throws -> VaultDataDirectory {
        try VaultDataDirectory.prepare(
            vaultPath: root,
            migrateLegacyData: false
        )
    }

    private func cleanup(root: String, dataDirectory: VaultDataDirectory) {
        try? FileManager.default.removeItem(at: dataDirectory.rootURL)
        try? FileManager.default.removeItem(atPath: root)
    }

    private func runGit(_ arguments: [String], at root: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RuntimeRecoveryGitInspectionError.commandFailed
        }
        return String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    private enum RuntimeRecoveryGitInspectionError: Error {
        case commandFailed
    }
}
