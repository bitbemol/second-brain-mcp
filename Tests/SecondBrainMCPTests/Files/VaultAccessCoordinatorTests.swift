import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Vault access coordinator` {
    @Test
    func `Reads overlap`() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let firstHold = AsyncHold()
        let secondEntry = EntryProbe()

        let first = Task {
            try await coordinator.withRead {
                await firstHold.enterAndWait()
            }
        }
        await firstHold.waitUntilEntered()
        let second = Task {
            try await coordinator.withRead {
                await secondEntry.markEntered()
            }
        }
        await secondEntry.waitUntilEntered()
        #expect(await secondEntry.entered)

        await firstHold.release()
        try await first.value
        try await second.value
    }

    @Test
    func `A waiting mutation blocks later reads until its complete chain finishes`() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let firstReadHold = AsyncHold()
        let mutationHold = AsyncHold()
        let laterRead = EntryProbe()

        let firstRead = Task {
            try await coordinator.withRead {
                await firstReadHold.enterAndWait()
            }
        }
        await firstReadHold.waitUntilEntered()

        let mutation = Task {
            try await coordinator.withMutation {
                await mutationHold.enterAndWait()
            }
        }
        while await coordinator.waitingOperationCount < 1 {
            await Task.yield()
        }

        let read = Task {
            try await coordinator.withRead {
                await laterRead.markEntered()
            }
        }
        while await coordinator.waitingOperationCount < 2 {
            await Task.yield()
        }
        #expect(await laterRead.entered == false)

        await firstReadHold.release()
        await mutationHold.waitUntilEntered()
        #expect(await laterRead.entered == false)

        await mutationHold.release()
        await laterRead.waitUntilEntered()
        try await firstRead.value
        try await mutation.value
        try await read.value
    }

    @Test
    func `Two runtime coordinators share one cross-process mutation lock`() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let contention = ContentionProbe()
        let firstCoordinator = fixture.coordinator()
        let secondCoordinator = fixture.coordinator {
            contention.record()
        }
        let firstHold = AsyncHold()
        let secondEntry = EntryProbe()

        let first = Task {
            try await firstCoordinator.withMutation {
                await firstHold.enterAndWait()
            }
        }
        await firstHold.waitUntilEntered()

        let second = Task {
            try await secondCoordinator.withMutation {
                await secondEntry.markEntered()
            }
        }
        await contention.waitUntilObserved()
        #expect(await secondEntry.entered == false)

        await firstHold.release()
        await secondEntry.waitUntilEntered()
        try await first.value
        try await second.value
    }

    @Test
    func `Cancellation removes a queued reader and failures release the lease`() async throws {
        enum Expected: Error { case failure }

        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let mutationHold = AsyncHold()

        let mutation = Task {
            try await coordinator.withMutation {
                await mutationHold.enterAndWait()
            }
        }
        await mutationHold.waitUntilEntered()

        let queuedRead = Task {
            try await coordinator.withRead {}
        }
        while await coordinator.waitingOperationCount == 0 {
            await Task.yield()
        }
        queuedRead.cancel()
        await #expect(throws: CancellationError.self) {
            try await queuedRead.value
        }

        await mutationHold.release()
        try await mutation.value

        await #expect(throws: Expected.self) {
            try await coordinator.withMutation {
                throw Expected.failure
            }
        }
        try await coordinator.withRead {}
    }
}

private struct CoordinatorFixture {
    let root: String
    let lockURL: URL

    init() throws {
        root = NSTemporaryDirectory() + "VaultAccessCoordinatorTests-\(UUID().uuidString)"
        let locks = URL(fileURLWithPath: root).appendingPathComponent(
            "locks",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: locks,
            withIntermediateDirectories: true
        )
        lockURL = locks.appendingPathComponent("vault-access.lock")
    }

    func coordinator(
        contentionObserver: (@Sendable () -> Void)? = nil
    ) -> VaultAccessCoordinator {
        VaultAccessCoordinator(
            lockURL: lockURL,
            contentionObserver: contentionObserver
        )
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

private actor AsyncHold {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor EntryProbe {
    private(set) var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        entered = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class ContentionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        lock.lock()
        observed = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func waitUntilObserved() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if observed {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
