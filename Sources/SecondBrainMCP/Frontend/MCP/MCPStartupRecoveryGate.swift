import Foundation

/// Lets discovery and reads use a connected transport while mutations await recovery.
actor MCPStartupRecoveryGate {
    private var operation: (@Sendable () async throws -> Void)?
    private var task: Task<Void, Error>?
    private var succeeded = false
    private var shuttingDown = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func install(
        _ operation: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Error> {
        precondition(self.operation == nil, "Startup recovery may only be installed once")
        self.operation = operation
        return startAttempt(operation)
    }

    private func startAttempt(
        _ operation: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Error> {
        precondition(task == nil, "Startup recovery already has an active attempt")
        let installed = Task {
            do {
                try await operation()
                finish(.success(()))
            } catch {
                finish(.failure(error))
                throw error
            }
        }
        task = installed
        return installed
    }

    func wait() async throws {
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        guard !succeeded else { return }
        if task == nil, let operation {
            _ = startAttempt(operation)
        }
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if succeeded {
                    continuation.resume()
                } else {
                    waiters[identifier] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(identifier) }
        }
        try Task.checkCancellation()
    }

    /// Stops and joins the currently active recovery attempt during server
    /// teardown, including a retry started by a later mutation.
    func shutdown() async {
        shuttingDown = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: CancellationError())
        }
        let active = task
        active?.cancel()
        _ = await active?.result
        task = nil
    }

    private func finish(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            succeeded = true
        case .failure:
            // A failed Git recovery describes the state of that attempt, not a
            // permanent server condition. The next mutation starts one retry.
            task = nil
        }
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            continuation.resume(with: result)
        }
    }

    private func cancelWaiter(_ identifier: UUID) {
        waiters.removeValue(forKey: identifier)?.resume(throwing: CancellationError())
    }
}
