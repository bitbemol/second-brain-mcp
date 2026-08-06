import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Vault mutation executor")
struct VaultMutationExecutorTests {
    @Test("Successful storage is committed with centralized metadata")
    func successfulMutation() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let store = VaultCRUDStore(vaultPath: root)
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let executor = VaultMutationExecutor(
            git: git,
            audit: AuditLogger(dataDirectory: dataDirectory)
        )
        let target = try WritableFileTarget.resolve(
            path: "notes/transaction.md",
            format: .markdown,
            vaultPath: root
        )

        let result = try await executor.execute(
            VaultMutationPlan(
                kind: .create,
                target: target,
                handler: .markdown
            ),
            apply: {
                try await store.create(target: target, data: Data("body".utf8))
                return "stored"
            }
        )

        #expect(result == "stored")
        #expect(try runGit(["log", "-1", "--pretty=%s"], at: root) ==
            "[SecondBrainMCP] Created markdown: notes/transaction.md\n")
        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
    }

    @Test("Storage failures pass through without Git failure wrapping")
    func storageFailure() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let store = VaultCRUDStore(vaultPath: root)
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let executor = VaultMutationExecutor(
            git: git,
            audit: AuditLogger(dataDirectory: dataDirectory)
        )
        let target = try WritableFileTarget.resolve(
            path: "notes/existing.md",
            format: .markdown,
            vaultPath: root
        )
        try Data("existing".utf8).write(to: target.url)

        await #expect(throws: VaultCRUDStore.StoreError.self) {
            try await executor.execute(
                VaultMutationPlan(
                    kind: .create,
                    target: target,
                    handler: .markdown
                ),
                apply: {
                    try await store.create(target: target, data: Data("replacement".utf8))
                }
            )
        }
    }

    @Test("Git failures report that persistence already succeeded")
    func gitFailure() async throws {
        let root = try makeVault()
        let store = VaultCRUDStore(vaultPath: root)
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let executor = VaultMutationExecutor(
            git: GitRepository(repoPath: root),
            audit: AuditLogger(dataDirectory: dataDirectory)
        )
        let target = try WritableFileTarget.resolve(
            path: "notes/uncommitted.md",
            format: .markdown,
            vaultPath: root
        )

        do {
            try await executor.execute(
                VaultMutationPlan(
                    kind: .create,
                    target: target,
                    handler: .markdown
                ),
                apply: {
                    try await store.create(target: target, data: Data("persisted".utf8))
                }
            )
            Issue.record("Expected Git sequencing to fail")
        } catch let error as VaultMutationExecutor.ExecutionError {
            guard case .gitCommitFailed(let path, _) = error else {
                Issue.record("Expected a post-persistence Git failure")
                return
            }
            #expect(path == target.relativePath)
        }

        #expect(FileManager.default.fileExists(atPath: target.url.path))
        let audit = try String(
            contentsOf: dataDirectory.auditLogURL,
            encoding: .utf8
        )
        #expect(audit.contains("git commit failed"))
    }

    @Test("Cancellation after persistence does not interrupt the Git commit")
    func postPersistenceCancellationStillCommits() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let store = VaultCRUDStore(vaultPath: root)
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let executor = VaultMutationExecutor(
            git: git,
            audit: AuditLogger(dataDirectory: dataDirectory)
        )
        let target = try WritableFileTarget.resolve(
            path: "notes/canceled-after-write.md",
            format: .markdown,
            vaultPath: root
        )

        let task = Task {
            try await executor.execute(
                VaultMutationPlan(
                    kind: .create,
                    target: target,
                    handler: .markdown
                ),
                apply: {
                    try await store.create(
                        target: target,
                        data: Data("persisted".utf8)
                    )
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        _ = try await task.value

        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
        #expect(
            try runGit(["show", "--pretty=format:", "--name-only", "HEAD"], at: root)
                .contains("notes/canceled-after-write.md")
        )
    }

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "VaultMutationExecutorTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        return root
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
            throw GitInspectionError.commandFailed
        }
        return String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    private enum GitInspectionError: Error {
        case commandFailed
    }
}
