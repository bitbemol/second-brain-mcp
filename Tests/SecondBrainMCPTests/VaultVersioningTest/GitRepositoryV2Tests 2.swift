import Foundation
import Testing
@testable import SecondBrainMCP

/// Integration coverage for the intentionally small vault-snapshot contract.
@Suite
struct `GitRepository V2` {
    /// Verifies that a brand-new vault with no `notes/` path is a successful
    /// no-op rather than Git's unmatched-pathspec failure.
    @Test
    func `an empty vault is already a valid snapshot`() async throws {
        let vault = try makeVault(createNotesDirectory: false)
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let repository = try makeRepository(for: vault)

        try await repository.recordSnapshot()
        try await repository.recordSnapshot()

        #expect(
            FileManager.default.fileExists(
                atPath: vault.root
                    .appendingPathComponent(".git")
                    .path(percentEncoded: false)
            )
        )
    }

    /// Verifies that snapshots are restricted to notes and that a clean request
    /// does not manufacture an additional commit.
    @Test
    func `snapshots notes and treats an unchanged vault as success`() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let repository = try makeRepository(for: vault)

        try Data("remember this".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )
        try Data("not a note".utf8).write(
            to: vault.root.appendingPathComponent("outside.txt"),
            options: .atomic
        )

        try await repository.recordSnapshot()
        let initialCommitCount = try runGit(
            ["rev-list", "--count", "HEAD"],
            in: vault.root
        )

        try await repository.recordSnapshot()

        #expect(initialCommitCount == "1")
        #expect(
            try runGit(["rev-list", "--count", "HEAD"], in: vault.root) == "1"
        )
        #expect(
            try runGit(["ls-files"], in: vault.root) == "notes/memory.md"
        )
    }

    /// Exercises separate actor instances sharing one lock, matching several MCP
    /// agents or processes that target the same vault concurrently.
    @Test
    func `concurrent snapshot requests share one reliable Git transaction`() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let agentCount = 16

        try await withThrowingTaskGroup(of: Void.self) { group in
            for agent in 0..<agentCount {
                group.addTask {
                    let repository = try makeRepository(for: vault)
                    try Data("agent \(agent)".utf8).write(
                        to: vault.notes.appendingPathComponent("note-\(agent).md"),
                        options: .atomic
                    )
                    try await repository.recordSnapshot()
                }
            }

            try await group.waitForAll()
        }

        let trackedNotes = try runGit(
            ["ls-files", "--", "notes"],
            in: vault.root
        ).split(separator: "\n")

        #expect(trackedNotes.count == agentCount)
        #expect(
            try runGit(
                ["status", "--porcelain", "--", "notes"],
                in: vault.root
            ).isEmpty
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: vault.root
                    .appendingPathComponent(".git/index.lock")
                    .path(percentEncoded: false)
            )
        )
    }

    /// Fixes the intended coalescing behavior in place: when two agents have
    /// already written their notes, whichever actor acquires the lock first
    /// commits both changes and the second actor succeeds against a clean index.
    @Test
    func `two agents can share one coalesced vault snapshot`() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let firstAgent = try makeRepository(for: vault)
        let secondAgent = try makeRepository(for: vault)

        try Data("first agent".utf8).write(
            to: vault.notes.appendingPathComponent("first.md"),
            options: .atomic
        )
        try Data("second agent".utf8).write(
            to: vault.notes.appendingPathComponent("second.md"),
            options: .atomic
        )

        async let firstSnapshot: Void = firstAgent.recordSnapshot()
        async let secondSnapshot: Void = secondAgent.recordSnapshot()
        _ = try await (firstSnapshot, secondSnapshot)

        let committedNotes = try runGit(
            ["show", "--pretty=", "--name-only", "HEAD", "--", "notes"],
            in: vault.root
        ).split(separator: "\n").map(String.init)

        #expect(Set(committedNotes) == ["notes/first.md", "notes/second.md"])
        #expect(
            try runGit(["rev-list", "--count", "HEAD"], in: vault.root) == "1"
        )
        #expect(
            try runGit(
                ["status", "--porcelain", "--", "notes"],
                in: vault.root
            ).isEmpty
        )
    }

    /// Verifies that removing the final note is staged even though `notes/` no
    /// longer exists in the working tree.
    @Test
    func `deleting every note is recorded`() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let repository = try makeRepository(for: vault)
        let note = vault.notes.appendingPathComponent("temporary.md")
        try Data("temporary".utf8).write(to: note, options: .atomic)
        try await repository.recordSnapshot()

        try FileManager.default.removeItem(at: vault.notes)
        try await repository.recordSnapshot()

        #expect(
            try runGit(["ls-files", "--", "notes"], in: vault.root).isEmpty
        )
        #expect(
            try runGit(["rev-list", "--count", "HEAD"], in: vault.root) == "2"
        )
    }
}

private extension `GitRepository V2` {
    /// Filesystem locations owned by one isolated integration test.
    struct TestVault: Sendable {
        let root: URL
        let notes: URL
        let lock: URL
    }

    /// Creates an isolated vault and the parent directory required by its lock.
    func makeVault(createNotesDirectory: Bool = true) throws -> TestVault {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitRepositoryV2Tests-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes")

        try FileManager.default.createDirectory(
            at: createNotesDirectory ? notes : root,
            withIntermediateDirectories: true
        )

        return TestVault(
            root: root,
            notes: notes,
            lock: root.appendingPathComponent(".vault-versioning.lock")
        )
    }

    /// Constructs an independently isolated actor that coordinates through the
    /// vault's shared cross-process lock file.
    func makeRepository(for vault: TestVault) throws -> GitRepositoryV2 {
        try GitRepositoryV2(
            repositoryURL: vault.root,
            lockURL: vault.lock
        )
    }

    /// Runs a small read-only Git assertion command and returns trimmed output.
    func runGit(_ arguments: [String], in repository: URL) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C",
            repository.path(percentEncoded: false),
        ] + arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw TestGitError(
                arguments: arguments,
                message: String(decoding: error, as: UTF8.self)
            )
        }

        return String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A compact diagnostic when a read-only Git assertion command fails.
    struct TestGitError: Error, CustomStringConvertible {
        let arguments: [String]
        let message: String

        var description: String {
            "git \(arguments.joined(separator: " ")) failed: \(message)"
        }
    }
}
