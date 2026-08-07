import Foundation

/// FIFO asynchronous single-permit gate with cancellation-aware waiters.
actor AsyncExclusiveGate {
    /// The configured queue is full, so retaining another suspended operation
    /// would violate the caller's aggregate resource policy.
    struct CapacityExceeded: Error, Sendable {}

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var locked = false
    private var waiters: [Waiter] = []
    private let maximumWaiters: Int?

    /// Creates a gate with an optional bound on suspended callers.
    ///
    /// A bounded queue also keeps the array-backed FIFO's removal work bounded.
    init(maximumWaiters: Int? = nil) {
        self.maximumWaiters = maximumWaiters.map { max($0, 0) }
    }

    /// Number of tasks currently suspended behind the active permit.
    var waitingCount: Int { waiters.count }

    /// Runs an async operation while holding the gate's single permit.
    ///
    /// A task canceled while queued is removed and resumed immediately; it does
    /// not wait for preceding work to finish merely to observe cancellation.
    func withPermit<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await acquire()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard locked else {
            locked = true
            return
        }
        if let maximumWaiters, waiters.count >= maximumWaiters {
            throw CapacityExceeded()
        }

        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
        guard acquired else { throw CancellationError() }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}
