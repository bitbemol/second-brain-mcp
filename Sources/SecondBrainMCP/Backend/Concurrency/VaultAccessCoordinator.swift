import Foundation

/// Shared/exclusive access boundary for one vault.
///
/// Every backend service receives the same instance from ``VaultRuntime``.
/// Independent MCP processes coordinate through the same advisory lock file.
protocol VaultAccessCoordinating: Sendable {
    /// Runs a read concurrently with other reads and never with a mutation.
    func withRead<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result

    /// Runs one complete mutation exclusively, including its Git snapshot.
    func withMutation<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result
}

/// Fair, writer-preferring reader/writer coordination for one complete vault.
actor VaultAccessCoordinator: VaultAccessCoordinating {
    /// The bounded queue cannot retain another suspended caller.
    struct CapacityExceeded: Error, CustomStringConvertible, Sendable {
        var description: String {
            "Vault operations are at capacity; retry after an active operation finishes"
        }
    }

    private enum Access: Sendable {
        case read
        case mutation
    }

    private struct Waiter {
        let id: UUID
        let access: Access
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var activeReaders = 0
    private var mutationActive = false
    private var waiters: [Waiter] = []
    private let maximumWaiters: Int
    private let processLock: POSIXAdvisoryFileLock

    /// Creates the one coordinator owned by a vault runtime.
    init(
        lockURL: URL,
        maximumWaiters: Int = 1_024,
        contentionObserver: (@Sendable () -> Void)? = nil
    ) {
        self.maximumWaiters = max(maximumWaiters, 0)
        self.processLock = POSIXAdvisoryFileLock(
            url: lockURL,
            contentionObserver: contentionObserver
        )
    }

    func withRead<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withAccess(.read, operation: operation)
    }

    func withMutation<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withAccess(.mutation, operation: operation)
    }

    /// Number of queued operations, exposed for deterministic concurrency tests.
    var waitingOperationCount: Int { waiters.count }

    private func withAccess<Result: Sendable>(
        _ access: Access,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await acquire(access)

        let lease: POSIXAdvisoryFileLock.Lease
        do {
            lease = try await processLock.acquire(
                access == .read ? .shared : .exclusive
            )
        } catch {
            release(access)
            throw error
        }

        do {
            try Task.checkCancellation()
            let result = try await operation()
            lease.release()
            release(access)
            return result
        } catch {
            lease.release()
            release(access)
            throw error
        }
    }

    private func acquire(_ access: Access) async throws {
        try Task.checkCancellation()
        if waiters.isEmpty, canAcquire(access) {
            activate(access)
            return
        }
        guard waiters.count < maximumWaiters else {
            throw CapacityExceeded()
        }

        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(
                    id: id,
                    access: access,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
        guard acquired else { throw CancellationError() }

        do {
            try Task.checkCancellation()
        } catch {
            release(access)
            throw error
        }
    }

    private func canAcquire(_ access: Access) -> Bool {
        switch access {
        case .read:
            !mutationActive
        case .mutation:
            !mutationActive && activeReaders == 0
        }
    }

    private func activate(_ access: Access) {
        switch access {
        case .read:
            activeReaders += 1
        case .mutation:
            mutationActive = true
        }
    }

    private func release(_ access: Access) {
        switch access {
        case .read:
            activeReaders -= 1
        case .mutation:
            mutationActive = false
        }
        drain()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
        drain()
    }

    private func drain() {
        guard !mutationActive, let first = waiters.first else { return }

        if first.access == .mutation {
            guard activeReaders == 0 else { return }
            waiters.removeFirst()
            mutationActive = true
            first.continuation.resume(returning: true)
            return
        }

        var readers: [Waiter] = []
        while waiters.first?.access == .read {
            readers.append(waiters.removeFirst())
            activeReaders += 1
        }
        readers.forEach { $0.continuation.resume(returning: true) }
    }
}
