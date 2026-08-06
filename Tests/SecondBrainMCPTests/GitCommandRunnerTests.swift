import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("GitCommandRunner")
struct GitCommandRunnerTests {
    @Test("Removes inherited Git repository redirection variables")
    func sanitizesGitEnvironment() {
        let environment = GitCommandRunner.sanitizedEnvironment([
            "PATH": "/usr/bin",
            "HOME": "/tmp/home",
            "GIT_DIR": "/tmp/foreign.git",
            "GIT_INDEX_FILE": "/tmp/foreign.index",
            "GIT_CONFIG_COUNT": "1",
        ])

        #expect(environment == ["PATH": "/usr/bin", "HOME": "/tmp/home"])
    }

    @Test("Returns standard output from Git")
    func returnsStandardOutput() async throws {
        let runner = GitCommandRunner()

        let output = try await runner.run(
            ["--version"],
            in: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        )

        #expect(output.hasPrefix("git version"))
    }

    @Test("Reports Git command failures with diagnostics")
    func reportsCommandFailure() async throws {
        let runner = GitCommandRunner()

        do {
            _ = try await runner.run(
                ["definitely-not-a-git-command"],
                in: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            )
            Issue.record("Expected the invalid Git command to fail")
        } catch let error as GitCommandError {
            guard case .commandFailed(let command, let exitCode, let stderr) = error else {
                Issue.record("Expected a command failure, received \(error)")
                return
            }
            #expect(command == "definitely-not-a-git-command")
            #expect(exitCode != 0)
            #expect(!stderr.isEmpty)
        }
    }

    @Test("Rejects a missing executable before launch")
    func rejectsMissingExecutable() async throws {
        let missingPath = NSTemporaryDirectory() + UUID().uuidString + "/git"
        let runner = GitCommandRunner(executableURL: URL(fileURLWithPath: missingPath))

        do {
            _ = try await runner.run(
                ["--version"],
                in: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            )
            Issue.record("Expected a missing executable failure")
        } catch let error as GitCommandError {
            guard case .executableNotFound(let path) = error else {
                Issue.record("Expected an executable-not-found failure, received \(error)")
                return
            }
            #expect(path == missingPath)
        }
    }

    @Test("Reports executable launch failures")
    func reportsLaunchFailure() async throws {
        let executablePath = NSTemporaryDirectory() + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: executablePath) }
        try "not a valid executable".write(
            toFile: executablePath,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executablePath
        )
        let runner = GitCommandRunner(executableURL: URL(fileURLWithPath: executablePath))

        do {
            _ = try await runner.run(
                [],
                in: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            )
            Issue.record("Expected an executable launch failure")
        } catch let error as GitCommandError {
            guard case .launchFailed = error else {
                Issue.record("Expected a launch failure, received \(error)")
                return
            }
        }
    }

    @Test("Cancellation terminates a running process")
    func cancellationTerminatesProcess() async throws {
        let runner = GitCommandRunner(
            executableURL: URL(fileURLWithPath: "/bin/sleep")
        )
        let task = Task {
            try await runner.run(
                ["10"],
                in: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            )
        }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected process execution to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
    }
}
