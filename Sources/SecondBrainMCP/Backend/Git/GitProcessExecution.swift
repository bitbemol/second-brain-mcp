import Darwin
import Foundation

/// Owns one Git child process from launch through termination or cancellation.
actor GitProcessExecution {
    private enum TerminationReason {
        case cancellation
        case timeout
    }

    private enum State {
        case ready
        case running
        case completed
    }

    private let executableURL: URL
    private let arguments: [String]
    private let workingDirectory: URL
    private let environment: [String: String]
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let standardInputFileDescriptor: Int32?
    private let command: String
    private let timeout: Duration
    private let terminationGrace: Duration
    private var state = State.ready
    private var continuation: CheckedContinuation<Int32, any Error>?
    private var processID: pid_t?
    private var terminationReason: TerminationReason?
    private var leaderExitCode: Int32?
    private var terminationGraceElapsed = false
    private var timeoutTask: Task<Void, Never>?
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
    private var outputReadsClosed = false

    /// Creates lifecycle state for one configured, not-yet-launched process.
    ///
    /// - Parameters:
    init(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        standardInputFileDescriptor: Int32? = nil,
        command: String,
        timeout: Duration,
        terminationGrace: Duration
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.standardInputFileDescriptor = standardInputFileDescriptor
        self.command = command
        self.timeout = timeout
        self.terminationGrace = terminationGrace
    }

    /// Launches the process and suspends until termination or task cancellation.
    ///
    /// - Returns: Operating-system process exit status.
    /// - Throws: ``GitCommandError/launchFailed(command:reason:)`` or
    ///   `CancellationError`.
    func run() async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await launchAndWait()
        } onCancel: {
            Task {
                await self.cancel()
            }
        }
    }

    /// Installs termination observation before launching the child process.
    private func launchAndWait() async throws -> Int32 {
        if Task.isCancelled {
            throw CancellationError()
        }
        precondition(state == .ready, "A process execution can only be started once")

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            do {
                let pid = try spawnProcessGroup()
                processID = pid
                state = .running
                closeParentWriteHandles()
                timeoutTask = Task { [weak self, timeout] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.requestTermination(.timeout)
                }
                Task.detached { [weak self] in
                    var status: Int32 = 0
                    var result: pid_t
                    repeat {
                        result = Darwin.waitpid(pid, &status, 0)
                    } while result < 0 && errno == EINTR
                    let exitCode: Int32
                    if result == pid {
                        let signal = status & 0x7f
                        exitCode = signal == 0
                            ? (status >> 8) & 0xff
                            : 128 + signal
                    } else {
                        exitCode = 128
                    }
                    await self?.processReaped(exitCode: exitCode)
                }
            } catch {
                state = .completed
                self.continuation = nil
                closeParentWriteHandles()
                continuation.resume(
                    throwing: error
                )
            }
        }
    }

    /// Requests cancellation but resumes only after the child is reaped and its
    /// entire process group has received the bounded TERM-to-KILL sequence.
    private func cancel() {
        switch state {
        case .ready:
            state = .completed
        case .running:
            requestTermination(.cancellation)
        case .completed:
            break
        }
    }

    /// Extends task cancellation across output draining after the leader exits.
    func cancelExecution() {
        cancel()
    }

    /// Waits for the TERM/KILL sequence and leader reap even when cancellation
    /// arrives after `run()` returned but before inherited pipes reach EOF.
    func cancelAndWait() async {
        if state == .completed { return }
        cancel()
        if state == .completed { return }
        if terminationGraceElapsed, leaderExitCode != nil { return }
        await withCheckedContinuation { continuation in
            terminationWaiters.append(continuation)
        }
    }

    private func requestTermination(_ reason: TerminationReason) {
        guard state == .running else { return }
        guard terminationReason == nil else { return }
        terminationReason = reason
        timeoutTask?.cancel()
        timeoutTask = nil
        if let processID {
            _ = Darwin.kill(-processID, SIGTERM)
        }
        Task { [weak self, terminationGrace] in
            do {
                try await Task.sleep(for: terminationGrace)
            } catch {
                return
            }
            await self?.terminationGraceDidElapse()
        }
    }

    private func terminationGraceDidElapse() {
        guard state == .running, terminationReason != nil else { return }
        terminationGraceElapsed = true
        if let processID {
            _ = Darwin.kill(-processID, SIGKILL)
        }
        // A descendant can escape the original process group with setsid(2)
        // while retaining inherited pipe writers. Closing our read endpoints
        // is the final bounded wakeup; FileHandle owns each descriptor and this
        // actor performs the close exactly once.
        closeOutputReads()
        finishTerminationIfPossible()
    }

    private func processReaped(exitCode: Int32) {
        guard state == .running else { return }
        leaderExitCode = exitCode
        if terminationReason == nil {
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: exitCode)
        } else {
            finishTerminationIfPossible()
        }
    }

    private func finishTerminationIfPossible() {
        guard state == .running,
              let reason = terminationReason,
              terminationGraceElapsed,
              leaderExitCode != nil else { return }
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        let continuation = continuation
        self.continuation = nil
        // If `run()` already returned because the leader exited, a descendant
        // can still own the output pipe. Preserve the timeout reason until the
        // runner confirms both pipes reached EOF.
        if continuation != nil {
            state = .completed
        }
        switch reason {
        case .cancellation:
            continuation?.resume(throwing: CancellationError())
        case .timeout:
            continuation?.resume(throwing: GitCommandError.timedOut(command: command))
        }
    }

    /// Ends the command deadline only after both output pipes reached EOF.
    /// This covers helpers that outlive an already-reaped Git leader.
    func outputDrainCompleted() throws {
        guard state == .running else { return }
        state = .completed
        timeoutTask?.cancel()
        timeoutTask = nil
        switch terminationReason {
        case .cancellation:
            throw CancellationError()
        case .timeout:
            throw GitCommandError.timedOut(command: command)
        case nil:
            return
        }
    }

    private func spawnProcessGroup() throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw GitCommandError.launchFailed(
                command: command,
                reason: "cannot initialize process attributes"
            )
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let stdoutRead = stdoutPipe.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrRead = stderrPipe.fileHandleForReading.fileDescriptor
        let stderrWrite = stderrPipe.fileHandleForWriting.fileDescriptor
        guard posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutRead) == 0,
              posix_spawn_file_actions_addclose(&actions, stderrRead) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutWrite) == 0,
              posix_spawn_file_actions_addclose(&actions, stderrWrite) == 0,
              posix_spawn_file_actions_addchdir(
                &actions,
                workingDirectory.path
              ) == 0,
              posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP)
              ) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw GitCommandError.launchFailed(
                command: command,
                reason: "cannot configure process group"
            )
        }
        if let standardInputFileDescriptor {
            guard posix_spawn_file_actions_adddup2(
                    &actions,
                    standardInputFileDescriptor,
                    STDIN_FILENO
                  ) == 0,
                  posix_spawn_file_actions_addclose(
                    &actions,
                    standardInputFileDescriptor
                  ) == 0 else {
                throw GitCommandError.launchFailed(
                    command: command,
                    reason: "cannot configure standard input"
                )
            }
        }

        let argumentStrings = [executableURL.path] + arguments
        let environmentStrings = environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let argumentPointers = argumentStrings.map { strdup($0) } + [nil]
        let environmentPointers = environmentStrings.map { strdup($0) } + [nil]
        defer {
            for pointer in argumentPointers.dropLast() { free(pointer) }
            for pointer in environmentPointers.dropLast() { free(pointer) }
        }

        var pid: pid_t = 0
        let result = executableURL.path.withCString { executable in
            argumentPointers.withUnsafeBufferPointer { argv in
                environmentPointers.withUnsafeBufferPointer { envp in
                    posix_spawn(
                        &pid,
                        executable,
                        &actions,
                        &attributes,
                        UnsafeMutablePointer(mutating: argv.baseAddress),
                        UnsafeMutablePointer(mutating: envp.baseAddress)
                    )
                }
            }
        }
        guard result == 0 else {
            throw GitCommandError.launchFailed(
                command: command,
                reason: String(cString: strerror(result))
            )
        }
        return pid
    }

    private func closeParentWriteHandles() {
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
    }

    private func closeOutputReads() {
        guard !outputReadsClosed else { return }
        outputReadsClosed = true
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
    }
}
