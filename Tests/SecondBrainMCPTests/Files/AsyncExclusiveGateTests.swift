import Testing
@testable import second_brain_mcp

/// Behavioral coverage for the reusable FIFO async serialization primitive.
@Suite
struct `Async exclusive gate` {
    @Test
    func `Runs concurrent operations one at a time`() async throws {
        let gate = AsyncExclusiveGate()
        let probe = CriticalSectionProbe()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await gate.withPermit {
                        await probe.enter()
                        await Task.yield()
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }

        let maximumConcurrency = await probe.maximumConcurrency
        #expect(maximumConcurrency == 1)
    }

    @Test
    func `A throwing operation releases the next permit`() async throws {
        let gate = AsyncExclusiveGate()
        do {
            let _: Void = try await gate.withPermit {
                throw GateTestError.expected
            }
            Issue.record("Expected the gated operation to throw")
        } catch GateTestError.expected {
            // The expected error must pass through unchanged.
        } catch {
            Issue.record("Unexpected gated error: \(error)")
        }

        // A second operation on the same gate must still acquire its permit.
        let value = try await gate.withPermit { 42 }
        #expect(value == 42)
    }

    @Test
    func `Cancellation while queued skips the operation and releases followers`() async throws {
        let gate = AsyncExclusiveGate()
        let hold = GateHold()
        let probe = CancellationProbe()

        let holder = Task {
            try await gate.withPermit {
                await hold.enterAndWait()
            }
        }
        await hold.waitUntilEntered()

        let canceled = Task {
            try await gate.withPermit {
                await probe.markCanceledOperationStarted()
            }
        }
        while await gate.waitingCount == 0 {
            await Task.yield()
        }
        canceled.cancel()

        while await gate.waitingCount > 0 {
            await Task.yield()
        }
        do {
            try await canceled.value
            Issue.record("Expected queued cancellation to propagate")
        } catch is CancellationError {
            // Cancellation completes without waiting for the held permit.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }

        let follower = Task {
            try await gate.withPermit { 42 }
        }

        await hold.release()
        try await holder.value

        let followerValue = try await follower.value
        let canceledOperationStarted = await probe.canceledOperationStarted
        #expect(followerValue == 42)
        #expect(!canceledOperationStarted)
    }

    @Test
    func `A bounded queue refuses to retain another suspended operation`() async throws {
        let gate = AsyncExclusiveGate(maximumWaiters: 1)
        let hold = GateHold()
        let holder = Task {
            try await gate.withPermit { await hold.enterAndWait() }
        }
        await hold.waitUntilEntered()
        let queued = Task { try await gate.withPermit { 1 } }
        while await gate.waitingCount != 1 { await Task.yield() }

        await #expect(throws: AsyncExclusiveGate.CapacityExceeded.self) {
            _ = try await gate.withPermit { 2 }
        }
        #expect(await gate.waitingCount == 1)

        queued.cancel()
        _ = try? await queued.value
        await hold.release()
        try await holder.value
    }

    @Test
    func `Reverse cancellation removes every waiter and leaves the gate usable`() async throws {
        let small = try await reverseCancellationDuration(count: 3_000)
        let large = try await reverseCancellationDuration(count: 12_000)

        // Actor scheduling and continuation resumption are part of these timings.
        // A wall-clock threshold in the concurrent suite confounds scheduler
        // contention with queue complexity. Keep latency visible, not as an
        // algorithmic oracle; the lookup-work test below guards reverse scans.
        print("GATE_REVERSE_CANCELLATION small=\(small) large=\(large)")
    }

    @Test
    func `Reverse removal lookup work is bounded independently of scheduler timing`() {
        let small = reverseRemovalLookupWork(count: 3_000)
        let large = reverseRemovalLookupWork(count: 12_000)

        // Count caller-observable Hashable callbacks, not elapsed scheduler time
        // or private storage. Allow dictionary collision/compaction variation,
        // while rejecting the millions of comparisons of a reverse linear scan.
        #expect(small <= 3_000 * 64)
        #expect(large <= 12_000 * 64)
        #expect(large <= small * 8)
        print("QUEUE_REVERSE_LOOKUP_WORK small=\(small) large=\(large)")
    }

    private func reverseRemovalLookupWork(count: Int) -> Int {
        let probe = QueueLookupProbe()
        var queue = IdentifiedFIFOQueue<CountedQueueID, Int>()
        for value in 0..<count {
            queue.append(value, id: CountedQueueID(value: value, probe: probe))
        }
        probe.reset()
        for value in (0..<count).reversed() {
            let removed = queue.remove(id: CountedQueueID(value: value, probe: probe))
            #expect(removed == value)
        }
        let work = probe.operations
        #expect(queue.count == 0)
        #expect(queue.isEmpty)
        #expect(queue.popFirst() == nil)

        // Fully canceled storage must remain reusable, including FIFO order.
        for value in 0..<3 {
            queue.append(value, id: CountedQueueID(value: value, probe: probe))
        }
        for expected in 0..<3 {
            #expect(queue.popFirst() == expected)
        }
        #expect(queue.isEmpty)
        return work
    }

    private func reverseCancellationDuration(
        count: Int
    ) async throws -> Duration {
        let gate = AsyncExclusiveGate()
        let hold = GateHold()
        let holder = Task {
            try await gate.withPermit { await hold.enterAndWait() }
        }
        await hold.waitUntilEntered()

        var queued: [Task<Void, Error>] = []
        queued.reserveCapacity(count)
        for _ in 0..<count {
            queued.append(Task {
                _ = try await gate.withPermit {
                    Issue.record("A canceled queued operation must never start")
                }
            })
        }
        while await gate.waitingCount != count {
            await Task.yield()
        }

        let clock = ContinuousClock()
        let start = clock.now
        for task in queued.reversed() {
            task.cancel()
        }
        for task in queued {
            do {
                try await task.value
                Issue.record("Every queued task must report cancellation")
            } catch is CancellationError {
                // Every canceled task finishes before the holder releases.
            } catch {
                Issue.record("Unexpected cancellation error: \(error)")
            }
        }
        let elapsed = start.duration(to: clock.now)
        #expect(await gate.waitingCount == 0)

        await hold.release()
        try await holder.value
        let next = try await gate.withPermit { 42 }
        #expect(next == 42)
        return elapsed
    }
}

private actor CriticalSectionProbe {
    private var activeOperations = 0
    private var observedMaximum = 0

    var maximumConcurrency: Int {
        observedMaximum
    }

    func enter() {
        activeOperations += 1
        observedMaximum = max(observedMaximum, activeOperations)
    }

    func leave() {
        activeOperations -= 1
    }
}

private actor GateHold {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CancellationProbe {
    private(set) var canceledOperationStarted = false

    func markCanceledOperationStarted() {
        canceledOperationStarted = true
    }
}

/// Used only synchronously by one test; no cross-task mutable state.
private final class QueueLookupProbe {
    private(set) var operations = 0

    func record() { operations += 1 }
    func reset() { operations = 0 }
}

private struct CountedQueueID: Hashable {
    let value: Int
    let probe: QueueLookupProbe

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.probe.record()
        return lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        probe.record()
        hasher.combine(value)
    }
}

private enum GateTestError: Error {
    case expected
}
