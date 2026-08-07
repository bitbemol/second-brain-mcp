import Testing
@testable import SecondBrainMCP

/// Behavioral coverage for the reusable FIFO async serialization primitive.
@Suite("Async exclusive gate")
struct AsyncExclusiveGateTests {
    @Test("Runs concurrent operations one at a time")
    func serializesOperations() async throws {
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

    @Test("A throwing operation releases the next permit")
    func releasesPermitAfterError() async throws {
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

    @Test("Cancellation while queued skips the operation and releases followers")
    func queuedCancellationSkipsOperation() async throws {
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

    @Test("A bounded queue refuses to retain another suspended operation")
    func boundedQueue() async throws {
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

private enum GateTestError: Error {
    case expected
}
