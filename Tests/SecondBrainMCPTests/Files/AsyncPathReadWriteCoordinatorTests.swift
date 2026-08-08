import Testing
@testable import SecondBrainMCP

@Suite("Async path reader/writer coordinator")
struct AsyncPathReadWriteCoordinatorTests {
    @Test("Readers for the same path overlap")
    func sameKeyReadersOverlap() async throws {
        let coordinator = AsyncPathReadWriteCoordinator()
        let overlap = PathOverlapProbe()

        let first = Task {
            try await coordinator.withAccess(key: "notes/shared.md", access: .read) {
                await overlap.enterAndWait()
            }
        }
        let second = Task {
            try await coordinator.withAccess(key: "notes/shared.md", access: .read) {
                await overlap.enterAndWait()
            }
        }

        await overlap.waitUntilEntered(2)
        #expect(await overlap.maximumActive == 2)
        await overlap.releaseAll()
        try await first.value
        try await second.value
        #expect(await coordinator.activePathCount == 0)
    }

    @Test("A queued writer excludes access and prevents later-reader barging")
    func writerFairness() async throws {
        let coordinator = AsyncPathReadWriteCoordinator()
        let initialReader = PathHold()
        let writerHold = PathHold()
        let events = PathEventProbe()
        let key = "notes/fair.md"

        let holder = Task {
            try await coordinator.withAccess(key: key, access: .read) {
                await initialReader.enterAndWait()
            }
        }
        await initialReader.waitUntilEntered()

        let writer = Task {
            return try await coordinator.withAccess(key: key, access: .write) {
                await events.record("writer-enter")
                await writerHold.enterAndWait()
                await events.record("writer-exit")
            }
        }
        while await coordinator.waitingCount(for: key) == 0 {
            await Task.yield()
        }

        let laterReader = Task {
            try await coordinator.withAccess(key: key, access: .read) {
                await events.record("late-reader")
            }
        }

        #expect(await events.snapshot().isEmpty)
        await initialReader.release()
        try await holder.value

        await writerHold.waitUntilEntered()
        #expect(await events.snapshot() == ["writer-enter"])
        await writerHold.release()
        try await writer.value
        try await laterReader.value

        #expect(await events.snapshot() == [
            "writer-enter", "writer-exit", "late-reader",
        ])
        #expect(await coordinator.activePathCount == 0)
    }

    @Test("Exclusive operations for different paths overlap")
    func differentKeysOverlap() async throws {
        let coordinator = AsyncPathReadWriteCoordinator()
        let overlap = PathOverlapProbe()

        let first = Task {
            try await coordinator.withAccess(key: "notes/a.md", access: .write) {
                await overlap.enterAndWait()
            }
        }
        let second = Task {
            try await coordinator.withAccess(key: "notes/b.md", access: .write) {
                await overlap.enterAndWait()
            }
        }

        await overlap.waitUntilEntered(2)
        #expect(await overlap.maximumActive == 2)
        #expect(await coordinator.activePathCount == 2)
        await overlap.releaseAll()
        try await first.value
        try await second.value
        #expect(await coordinator.activePathCount == 0)
    }

    @Test("Canceling a queued waiter skips its operation and removes path state")
    func queuedCancellationCleansState() async throws {
        let coordinator = AsyncPathReadWriteCoordinator()
        let holderGate = PathHold()
        let operationProbe = PathCancellationProbe()
        let key = "notes/canceled.md"

        let holder = Task {
            try await coordinator.withAccess(key: key, access: .write) {
                await holderGate.enterAndWait()
            }
        }
        await holderGate.waitUntilEntered()

        let canceled = Task {
            return try await coordinator.withAccess(key: key, access: .read) {
                await operationProbe.markStarted()
            }
        }
        while await coordinator.waitingCount(for: key) == 0 {
            await Task.yield()
        }
        canceled.cancel()

        do {
            try await canceled.value
            Issue.record("Expected queued cancellation to propagate")
        } catch is CancellationError {
            // The canceled lease must complete while the writer is still held.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        #expect(await operationProbe.started == false)

        await holderGate.release()
        try await holder.value
        #expect(await coordinator.activePathCount == 0)
    }

    @Test("A saturated path queue rejects excess callers without losing queued work")
    func boundedQueue() async throws {
        let coordinator = AsyncPathReadWriteCoordinator(
            maximumWaitersPerPath: 1,
            maximumTotalWaiters: 1
        )
        let holderGate = PathHold()
        let key = "notes/saturated.md"
        let holder = Task {
            try await coordinator.withAccess(key: key, access: .write) {
                await holderGate.enterAndWait()
            }
        }
        await holderGate.waitUntilEntered()
        let queued = Task {
            try await coordinator.withAccess(key: key, access: .read) { 42 }
        }
        while await coordinator.waitingCount(for: key) != 1 {
            await Task.yield()
        }

        await #expect(throws: AsyncPathReadWriteCoordinator.CapacityExceeded.self) {
            _ = try await coordinator.withAccess(key: key, access: .read) { 7 }
        }
        #expect(await coordinator.waitingCount(for: key) == 1)

        await holderGate.release()
        try await holder.value
        #expect(try await queued.value == 42)
        #expect(await coordinator.activePathCount == 0)
    }

    @Test("The reader holder cap queues excess readers without breaking progress")
    func boundedReaderHolders() async throws {
        let coordinator = AsyncPathReadWriteCoordinator(
            maximumReadersPerPath: 1,
            maximumWaitersPerPath: 1,
            maximumTotalWaiters: 1
        )
        let firstHold = PathHold()
        let secondProbe = PathCancellationProbe()
        let key = "secondbrain://notes-tree"

        let first = Task {
            try await coordinator.withAccess(key: key, access: .read) {
                await firstHold.enterAndWait()
            }
        }
        await firstHold.waitUntilEntered()

        let second = Task {
            try await coordinator.withAccess(key: key, access: .read) {
                await secondProbe.markStarted()
            }
        }
        while await coordinator.waitingCount(for: key) != 1 {
            await Task.yield()
        }
        #expect(await secondProbe.started == false)

        await firstHold.release()
        try await first.value
        try await second.value
        #expect(await secondProbe.started)
        #expect(await coordinator.activePathCount == 0)
    }
}

/// Tracks active operations and holds them until the test releases the cohort.
private actor PathOverlapProbe {
    private var active = 0
    private var entered = 0
    private(set) var maximumActive = 0
    private var enteredWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        active += 1
        entered += 1
        maximumActive = max(maximumActive, active)
        resumeSatisfiedEnteredWaiters()

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        active -= 1
    }

    func waitUntilEntered(_ count: Int) async {
        guard entered < count else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append((count, continuation))
        }
    }

    func releaseAll() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func resumeSatisfiedEnteredWaiters() {
        var pending: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in enteredWaiters {
            if entered >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        enteredWaiters = pending
    }
}

/// Holds one operation and exposes deterministic entered/release handshakes.
private actor PathHold {
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

/// Records the order in which protected operations actually enter and leave.
private actor PathEventProbe {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

/// Detects whether a canceled waiter's protected closure was ever invoked.
private actor PathCancellationProbe {
    private(set) var started = false

    func markStarted() {
        started = true
    }
}
