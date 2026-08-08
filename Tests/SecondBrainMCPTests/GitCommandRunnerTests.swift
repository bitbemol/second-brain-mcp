import Foundation
import Testing
@testable import SecondBrainMCP

// Process-group and pipe lifecycle probes intentionally manipulate signals and
// inherited descriptors; serialize them so one probe cannot perturb another.
@Suite("GitCommandRunner", .serialized)
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

    @Test("Deadline kills a TERM-resistant process group holding output pipes")
    func deadlineKillsTermResistantDescendants() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitCommandRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("resists-term")
        try """
        #!/bin/sh
        (
          trap '' TERM
          while true; do
            printf x
            /bin/sleep 1
          done
        ) &
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let runner = GitCommandRunner(
            executableURL: executable,
            timeout: .milliseconds(80),
            terminationGrace: .milliseconds(50)
        )
        do {
            _ = try await runner.run([], in: directory)
            Issue.record("Expected the injected command to time out")
        } catch let error as GitCommandError {
            guard case .timedOut = error else {
                Issue.record("Expected timeout, received \(error)")
                return
            }
        }

    }

    @Test("Deadline wakes drains retained by a setsid-escaped descendant")
    func deadlineClosesEscapedSessionPipes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitCommandRunnerSetsid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let program = #"""
        use POSIX qw(setsid);
        my $pidfile = shift;
        my $child = fork();
        die "fork" unless defined $child;
        if ($child == 0) {
          setsid();
          $SIG{TERM} = 'IGNORE';
          open(my $fh, '>', $pidfile) or die "pidfile";
          print $fh $$;
          close($fh);
          while (1) { print "x"; select(undef, undef, undef, 0.05); }
        }
        exit 0;
        """#
        let runner = GitCommandRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            timeout: .milliseconds(80),
            terminationGrace: .milliseconds(50)
        )
        defer {
            if let raw = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(raw) {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }

        do {
            _ = try await runner.run(["-e", program, pidFile.path], in: directory)
            Issue.record("Expected the escaped pipe holder to time out")
        } catch let error as GitCommandError {
            guard case .timedOut = error else {
                Issue.record("Expected timeout, received \(error)")
                return
            }
        }

        #expect(FileManager.default.fileExists(atPath: pidFile.path))
    }
}
