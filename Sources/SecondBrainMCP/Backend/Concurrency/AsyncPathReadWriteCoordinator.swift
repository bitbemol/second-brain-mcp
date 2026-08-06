import Foundation

/// Fair, cancellation-aware reader/writer coordination keyed by canonical path.
actor AsyncPathReadWriteCoordinator {
    /// Access mode held for one protected operation.
    enum Access: Sendable {
        /// May overlap other readers for the same key.
        case read
        /// Excludes every other reader and writer for the same key.
        case write
    }

    private struct Waiter {
        let id: UUID
        let access: Access
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var readers = 0
        var writer = false
        var waiters: [Waiter] = []
    }

    private var states: [String: State] = [:]

    /// Number of path identities that currently have holders or waiters.
    var activePathCount: Int { states.count }

    /// Number of queued leases for one canonical path identity.
    func waitingCount(for key: String) -> Int {
        states[key]?.waiters.count ?? 0
    }

    /// Runs an operation under a fair path-specific read or write lease.
    ///
    /// Consecutive readers at the front of the queue start together. Once a
    /// writer is queued, later readers cannot bypass it.
    func withAccess<Result: Sendable>(
        key: String,
        access: Access,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await acquire(key: key, access: access)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(key: key, access: access)
            return result
        } catch {
            release(key: key, access: access)
            throw error
        }
    }

    private func acquire(key: String, access: Access) async throws {
        try Task.checkCancellation()
        var state = states[key] ?? State()
        if state.waiters.isEmpty, canAcquire(access, in: state) {
            activate(access, in: &state)
            states[key] = state
            return
        }

        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                var queued = states[key] ?? State()
                queued.waiters.append(Waiter(
                    id: id,
                    access: access,
                    continuation: continuation
                ))
                states[key] = queued
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id, key: key) }
        }
        guard acquired else { throw CancellationError() }
        do {
            try Task.checkCancellation()
        } catch {
            release(key: key, access: access)
            throw error
        }
    }

    private func canAcquire(_ access: Access, in state: State) -> Bool {
        switch access {
        case .read: !state.writer
        case .write: !state.writer && state.readers == 0
        }
    }

    private func activate(_ access: Access, in state: inout State) {
        switch access {
        case .read: state.readers += 1
        case .write: state.writer = true
        }
    }

    private func cancelWaiter(id: UUID, key: String) {
        guard var state = states[key],
              let index = state.waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = state.waiters.remove(at: index)
        states[key] = state
        waiter.continuation.resume(returning: false)
        drain(key: key)
    }

    private func release(key: String, access: Access) {
        guard var state = states[key] else { return }
        switch access {
        case .read: state.readers -= 1
        case .write: state.writer = false
        }
        states[key] = state
        drain(key: key)
    }

    private func drain(key: String) {
        guard var state = states[key], !state.writer else { return }

        if state.readers > 0 {
            guard state.waiters.first?.access == .read else {
                states[key] = state
                return
            }
        }

        if state.readers == 0, state.waiters.first?.access == .write {
            let waiter = state.waiters.removeFirst()
            state.writer = true
            states[key] = state
            waiter.continuation.resume(returning: true)
            return
        }

        var resumed: [Waiter] = []
        while state.waiters.first?.access == .read {
            resumed.append(state.waiters.removeFirst())
            state.readers += 1
        }

        if state.readers == 0, !state.writer, state.waiters.isEmpty {
            states.removeValue(forKey: key)
        } else {
            states[key] = state
        }
        resumed.forEach { $0.continuation.resume(returning: true) }
    }
}

extension AsyncPathReadWriteCoordinator.Access: Equatable {}
