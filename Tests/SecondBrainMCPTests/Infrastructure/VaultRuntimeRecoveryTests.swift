import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Vault runtime recovery bootstrap")
struct VaultRuntimeRecoveryTests {
    @Test("An unresolved active transaction starts without snapshotting dirty state")
    func unresolvedTransactionSkipsGitBootstrap() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "unresolved-startup")
        try receipts.saveInProgress(
            identifier: identifier,
            fingerprint: fingerprint
        )
        try receipts.saveActiveTransaction(
            identifier: identifier,
            fingerprint: fingerprint
        )
        try Data("must not be snapshotted".utf8).write(
            to: URL(fileURLWithPath: root)
                .appendingPathComponent("notes/unresolved.md"),
            options: .atomic
        )

        _ = try await VaultRuntime.bootstrap(vaultPath: root)

        #expect(try receipts.activeTransaction()?.identifier == identifier)
        #expect(try !runGit(["status", "--porcelain"], at: root).isEmpty)
    }

    @Test("A completed receipt clears its stale marker before normal bootstrap")
    func completedTransactionAllowsGitBootstrap() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "completed-startup")
        let path = "notes/completed-startup.md"
        let data = Data("safe to snapshot".utf8)
        try data.write(
            to: URL(fileURLWithPath: root).appendingPathComponent(path),
            options: .atomic
        )
        try receipts.save(
            identifier: identifier,
            fingerprint: fingerprint,
            output: FileOperationOutput.text("Created")
                .withMetadata(FileOperationMetadata(
                    path: path,
                    area: .notes,
                    revision: FileSnapshot(data: data, modifiedDate: nil).revision,
                    mutationID: identifier,
                    replayed: false
                ))
        )
        try receipts.saveActiveTransaction(
            identifier: identifier,
            fingerprint: fingerprint
        )

        _ = try await VaultRuntime.bootstrap(vaultPath: root)

        #expect(try receipts.activeTransaction() == nil)
        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
        #expect(
            try runGit(["log", "-1", "--pretty=%s"], at: root)
                .contains("Snapshot of uncommitted changes on startup")
        )
    }

    @Test("Corrupt active recovery state fails bootstrap loudly")
    func corruptActiveMarkerFailsBootstrap() async throws {
        let root = try makeVault()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        try Data("{".utf8).write(
            to: dataDirectory.rootURL.appendingPathComponent("active-mutation.json"),
            options: .atomic
        )

        await #expect(throws: MutationReceiptStore.ReceiptError.self) {
            _ = try await VaultRuntime.bootstrap(vaultPath: root)
        }
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
