import Foundation

/// Lets discovery and reads use a connected transport while mutations await recovery.
actor MCPStartupRecoveryGate {
    private var task: Task<Void, Error>?
    private var result: Result<Void, Error>?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func install(
        _ operation: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Error> {
        precondition(task == nil, "Startup recovery may only be installed once")
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
        if let result {
            try result.get()
            return
        }
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let result {
                    continuation.resume(with: result)
                } else {
                    waiters[identifier] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(identifier) }
        }
        try Task.checkCancellation()
    }

    private func finish(_ result: Result<Void, Error>) {
        self.result = result
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
