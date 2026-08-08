import Darwin
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
    private let timeout: Duration
    private let terminationGrace: Duration
    private let commandObserver: (@Sendable ([String]) -> Void)?

    /// Creates a runner backed by the system Git executable.
    ///
    /// - Parameter executableURL: Git executable to invoke. Injection keeps
    ///   executable availability and failure behavior independently testable.
    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        timeout: Duration = .seconds(10 * 60),
        terminationGrace: Duration = .milliseconds(150),
        commandObserver: (@Sendable ([String]) -> Void)? = nil
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.terminationGrace = terminationGrace
        self.commandObserver = commandObserver
    }

    /// Executes one Git command inside a working tree.
    ///
    /// - Parameters:
    ///   - arguments: Arguments passed directly to Git without shell parsing.
    ///   - workingDirectory: Directory in which Git should run.
    /// - Returns: The command's UTF-8 standard output.
    /// - Throws: ``GitCommandError`` or `CancellationError`.
    @discardableResult
    func run(
        _ arguments: [String],
        in workingDirectory: URL,
        gitIndexFile: URL? = nil
    ) async throws -> String {
        let data = try await execute(
            arguments,
            in: workingDirectory,
            maximumStandardOutputBytes: Self.maximumCapturedBytes,
            gitIndexFile: gitIndexFile
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Executes Git and returns bounded raw standard output.
    ///
    /// Repository policy uses this only for immutable blob contents whose
    /// expected resource limit is already known. One extra byte can be requested
    /// by the caller so oversized output remains distinguishable from exact-cap
    /// output without retaining the complete stream.
    func runData(
        _ arguments: [String],
        in workingDirectory: URL,
        maximumCapturedBytes: Int,
        gitIndexFile: URL? = nil,
        standardInput: Data? = nil
    ) async throws -> Data {
        try await execute(
            arguments,
            in: workingDirectory,
            maximumStandardOutputBytes: maximumCapturedBytes,
            gitIndexFile: gitIndexFile,
            standardInput: standardInput
        )
    }

    private func execute(
        _ arguments: [String],
        in workingDirectory: URL,
        maximumStandardOutputBytes: Int,
        gitIndexFile: URL?,
        standardInput: Data? = nil
    ) async throws -> Data {
        commandObserver?(arguments)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GitCommandError.executableNotFound(path: executableURL.path)
        }

        var environment = Self.sanitizedEnvironment(
            ProcessInfo.processInfo.environment
        )
        if let gitIndexFile {
            // Only this narrowly typed override is allowed back after stripping
            // inherited GIT_* variables. Callers create it in private process
            // storage and Git uses it solely as an isolated staging index.
            environment["GIT_INDEX_FILE"] = gitIndexFile.standardized.path
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let command = arguments.joined(separator: " ")
        let inputDescriptor = try standardInput.map {
            try Self.materializeStandardInput($0, command: command)
        }
        defer {
            if let inputDescriptor {
                Darwin.close(inputDescriptor)
            }
        }
        let execution = GitProcessExecution(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            standardInputFileDescriptor: inputDescriptor,
            command: command,
            timeout: timeout,
            terminationGrace: terminationGrace
        )
        async let exitCode = execution.run()
        let stdout = Task {
            try await Self.readAll(
                stdoutPipe.fileHandleForReading.bytes,
                maximumBytes: maximumStandardOutputBytes
            )
        }
        let stderr = Task {
            try await Self.readAll(
                stderrPipe.fileHandleForReading.bytes,
                maximumBytes: Self.maximumCapturedBytes
            )
        }
        defer {
            stdout.cancel()
            stderr.cancel()
        }

        let completedExitCode: Int32
        do {
            completedExitCode = try await exitCode
        } catch {
            _ = try? await stdout.value
            _ = try? await stderr.value
            throw error
        }
        let completedStdout: Data
        let completedStderr: Data
        do {
            (completedStdout, completedStderr) = try await withTaskCancellationHandler {
                try await (stdout.value, stderr.value)
            } onCancel: {
                Task { await execution.cancelExecution() }
            }
        } catch {
            if Task.isCancelled {
                await execution.cancelAndWait()
                throw CancellationError()
            }
            // A timeout deliberately closes the parent read endpoints to wake
            // drains held open by a setsid-escaped descendant. Translate that
            // expected FileHandle error back to the lifecycle's primary result.
            try await execution.outputDrainCompleted()
            throw error
        }
        try await execution.outputDrainCompleted()
        let stderrText = String(decoding: completedStderr, as: UTF8.self)
        guard completedExitCode == 0 else {
            throw GitCommandError.commandFailed(
                command: command,
                exitCode: completedExitCode,
                stderr: stderrText
            )
        }
        return completedStdout
    }

    /// Materializes bounded batch input into an immediately unlinked private
    /// file. The descriptor has no pathname to retain or scavenge, cannot block
    /// like a prefilled pipe, and remains stable until the spawned child dup2s it.
    private static func materializeStandardInput(
        _ data: Data,
        command: String
    ) throws -> Int32 {
        let template = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainMCP-git-input-XXXXXX")
            .path
        var bytes = Array(template.utf8CString)
        let descriptor = bytes.withUnsafeMutableBufferPointer { buffer in
            Darwin.mkstemp(buffer.baseAddress!)
        }
        guard descriptor >= 0 else {
            throw GitCommandError.launchFailed(
                command: command,
                reason: "cannot create private standard input"
            )
        }
        _ = bytes.withUnsafeBufferPointer { buffer in
            Darwin.unlink(buffer.baseAddress!)
        }
        do {
            guard Darwin.fchmod(descriptor, 0o600) == 0,
                  Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw GitCommandError.launchFailed(
                    command: command,
                    reason: "cannot protect private standard input"
                )
            }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let result = Darwin.write(
                        descriptor,
                        buffer.baseAddress!.advanced(by: offset),
                        buffer.count - offset
                    )
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else {
                        throw GitCommandError.launchFailed(
                            command: command,
                            reason: "cannot write private standard input"
                        )
                    }
                    offset += result
                }
            }
            guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw GitCommandError.launchFailed(
                    command: command,
                    reason: "cannot rewind private standard input"
                )
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func readAll(
        _ bytes: FileHandle.AsyncBytes,
        maximumBytes: Int
    ) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            if data.count < maximumBytes {
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
