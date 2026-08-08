import Foundation

/// Fair, cancellation-aware reader/writer coordination keyed by canonical path.
actor AsyncPathReadWriteCoordinator {
    /// The configured suspended-caller budget was exhausted.
    struct CapacityExceeded: Error, Sendable {}

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
        var waiters: [Waiter?] = []
        var waiterIndices: [UUID: Int] = [:]
        var waiterHead = 0
        var waiterCount = 0

        var firstWaiter: Waiter? {
            guard waiterHead < waiters.count else { return nil }
            for index in waiterHead..<waiters.count {
                if let waiter = waiters[index] { return waiter }
            }
            return nil
        }

        mutating func append(_ waiter: Waiter) {
            waiterIndices[waiter.id] = waiters.endIndex
            waiters.append(waiter)
            waiterCount += 1
        }

        mutating func popFirst() -> Waiter? {
            while waiterHead < waiters.count {
                let index = waiterHead
                waiterHead += 1
                guard let waiter = waiters[index] else { continue }
                waiters[index] = nil
                waiterIndices.removeValue(forKey: waiter.id)
                waiterCount -= 1
                compactIfUseful()
                return waiter
            }
            compactIfUseful()
            return nil
        }

        mutating func remove(id: UUID) -> Waiter? {
            guard let index = waiterIndices.removeValue(forKey: id),
                  let waiter = waiters[index] else { return nil }
            waiters[index] = nil
            waiterCount -= 1
            if index == waiterHead {
                while waiterHead < waiters.count,
                      waiters[waiterHead] == nil {
                    waiterHead += 1
                }
            }
            compactIfUseful()
            return waiter
        }

        private mutating func compactIfUseful() {
            guard waiterHead > 64,
                  waiterHead * 2 >= waiters.count else { return }
            waiters = Array(waiters[waiterHead...])
            waiterHead = 0
            waiterIndices.removeAll(keepingCapacity: true)
            for (index, waiter) in waiters.enumerated() {
                if let waiter { waiterIndices[waiter.id] = index }
            }
        }
    }

    private var states: [String: State] = [:]
    private var totalWaiterCount = 0
    private let maximumReadersPerPath: Int
    private let maximumWaitersPerPath: Int
    private let maximumTotalWaiters: Int

    init(
        maximumReadersPerPath: Int = 128,
        maximumWaitersPerPath: Int = 256,
        maximumTotalWaiters: Int = 1_024
    ) {
        self.maximumReadersPerPath = max(maximumReadersPerPath, 1)
        self.maximumWaitersPerPath = max(maximumWaitersPerPath, 0)
        self.maximumTotalWaiters = max(maximumTotalWaiters, 0)
    }

    /// Number of path identities that currently have holders or waiters.
    var activePathCount: Int { states.count }

    /// Number of queued leases for one canonical path identity.
    func waitingCount(for key: String) -> Int {
        states[key]?.waiterCount ?? 0
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
        if state.waiterCount == 0, canAcquire(access, in: state) {
            activate(access, in: &state)
            states[key] = state
            return
        }
        guard state.waiterCount < maximumWaitersPerPath,
              totalWaiterCount < maximumTotalWaiters else {
            throw CapacityExceeded()
        }

        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                var queued = states[key] ?? State()
                queued.append(Waiter(
                    id: id,
                    access: access,
                    continuation: continuation
                ))
                states[key] = queued
                totalWaiterCount += 1
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
        case .read: !state.writer && state.readers < maximumReadersPerPath
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
              let waiter = state.remove(id: id) else {
            return
        }
        totalWaiterCount -= 1
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
            guard state.firstWaiter?.access == .read else {
                states[key] = state
                return
            }
        }

        if state.readers == 0, state.firstWaiter?.access == .write,
           let waiter = state.popFirst() {
            totalWaiterCount -= 1
            state.writer = true
            states[key] = state
            waiter.continuation.resume(returning: true)
            return
        }

        var resumed: [Waiter] = []
        while state.readers < maximumReadersPerPath,
              state.firstWaiter?.access == .read,
              let waiter = state.popFirst() {
            totalWaiterCount -= 1
            resumed.append(waiter)
            state.readers += 1
        }

        if state.readers == 0, !state.writer, state.waiterCount == 0 {
            states.removeValue(forKey: key)
        } else {
            states[key] = state
        }
        resumed.forEach { $0.continuation.resume(returning: true) }
    }
}

extension AsyncPathReadWriteCoordinator.Access: Equatable {}
