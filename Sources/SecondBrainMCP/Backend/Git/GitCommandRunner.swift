import Foundation

/// Runs Git commands without exposing process management to repository policy.
///
/// Standard output and standard error are drained concurrently. This prevents a
/// verbose Git command from filling either pipe and blocking while it waits for
/// the parent process to read its output.
struct GitCommandRunner: Sendable {
    /// Maximum bytes retained independently from standard output and error.
    static let maximumCapturedBytes = 1024 * 1024

    private let executableURL: URL

    /// Creates a runner backed by the system Git executable.
    ///
    /// - Parameter executableURL: Git executable to invoke. Injection keeps
    ///   executable availability and failure behavior independently testable.
    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.executableURL = executableURL
    }

    /// Executes one Git command inside a working tree.
    ///
    /// - Parameters:
    ///   - arguments: Arguments passed directly to Git without shell parsing.
    ///   - workingDirectory: Directory in which Git should run.
    /// - Returns: The command's UTF-8 standard output.
    /// - Throws: ``GitCommandError`` or `CancellationError`.
    @discardableResult
    func run(_ arguments: [String], in workingDirectory: URL) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GitCommandError.executableNotFound(path: executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.sanitizedEnvironment(
            ProcessInfo.processInfo.environment
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let command = arguments.joined(separator: " ")
        let execution = GitProcessExecution(process: process, command: command)
        async let exitCode = execution.run()
        async let stdout = Self.readAll(stdoutPipe.fileHandleForReading.bytes)
        async let stderr = Self.readAll(stderrPipe.fileHandleForReading.bytes)

        let (completedExitCode, completedStdout, completedStderr) = try await (
            exitCode,
            stdout,
            stderr
        )
        let stderrText = String(decoding: completedStderr, as: UTF8.self)
        guard completedExitCode == 0 else {
            throw GitCommandError.commandFailed(
                command: command,
                exitCode: completedExitCode,
                stderr: stderrText
            )
        }
        return String(decoding: completedStdout, as: UTF8.self)
    }

    private static func readAll(_ bytes: FileHandle.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            if data.count < maximumCapturedBytes {
                data.append(byte)
            }
        }
        return data
    }

    /// Removes Git control variables that could redirect commands outside `cwd`.
    static func sanitizedEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        environment.filter { key, _ in !key.hasPrefix("GIT_") }
    }
}
