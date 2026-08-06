import Foundation

/// Owns one Git child process from launch through termination or cancellation.
actor GitProcessExecution {
    private enum State {
        case ready
        case running
        case completed
        case cancelled
    }

    private let process: Process
    private let command: String
    private var state = State.ready
    private var continuation: CheckedContinuation<Int32, any Error>?

    /// Creates lifecycle state for one configured, not-yet-launched process.
    ///
    /// - Parameters:
    ///   - process: Configured Foundation process owned by this execution.
    ///   - command: Human-readable arguments used if launch fails.
    init(process: Process, command: String) {
        self.process = process
        self.command = command
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
        if state == .cancelled {
            throw CancellationError()
        }
        precondition(state == .ready, "A process execution can only be started once")

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            process.terminationHandler = { [weak self] finishedProcess in
                let exitCode = finishedProcess.terminationStatus
                Task {
                    await self?.complete(exitCode: exitCode)
                }
            }

            do {
                try process.run()
                state = .running
            } catch {
                state = .completed
                self.continuation = nil
                process.terminationHandler = nil
                continuation.resume(
                    throwing: GitCommandError.launchFailed(
                        command: command,
                        reason: error.localizedDescription
                    )
                )
            }
        }
    }

    /// Terminates a running process and resumes its waiter with cancellation.
    private func cancel() {
        switch state {
        case .ready:
            state = .cancelled
        case .running:
            state = .cancelled
            let continuation = self.continuation
            self.continuation = nil
            if process.isRunning {
                process.terminate()
            }
            continuation?.resume(throwing: CancellationError())
        case .completed, .cancelled:
            break
        }
    }

    /// Resumes the waiter when a running process terminates normally.
    private func complete(exitCode: Int32) {
        guard state == .running else { return }
        state = .completed
        let continuation = self.continuation
        self.continuation = nil
        process.terminationHandler = nil
        continuation?.resume(returning: exitCode)
    }
}
