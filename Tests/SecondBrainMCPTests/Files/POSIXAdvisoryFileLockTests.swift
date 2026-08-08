import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("POSIX advisory file lock")
struct POSIXAdvisoryFileLockTests {
    @Test("Independent shared leases keep a writer excluded until both close")
    func independentSharedLeases() async throws {
        let url = try lockURL()
        let first = POSIXAdvisoryFileLock(
            url: url,
            retryNanoseconds: 1_000_000
        )
        let second = POSIXAdvisoryFileLock(
            url: url,
            retryNanoseconds: 1_000_000
        )
        let firstLease = try await first.acquire(.shared)
        let secondLease = try await second.acquire(.shared)
        let probe = AdvisoryLockProbe()
        let contention = AdvisoryContentionProbe()

        let writer = Task {
            try await POSIXAdvisoryFileLock(
                url: url,
                retryNanoseconds: 1_000_000,
                contentionObserver: { contention.mark() }
            ).withLock(.exclusive) {
                await probe.enter()
            }
        }
        while !contention.observed { await Task.yield() }
        #expect(await probe.entered == false)

        firstLease.release()
        let previousContentionCount = contention.count
        while contention.count <= previousContentionCount { await Task.yield() }
        #expect(await probe.entered == false)

        secondLease.release()
        try await writer.value
        #expect(await probe.entered)
    }

    @Test("A canceled waiter never acquires the protected operation")
    func canceledWaiter() async throws {
        let url = try lockURL()
        let contention = AdvisoryContentionProbe()
        let lock = POSIXAdvisoryFileLock(
            url: url,
            retryNanoseconds: 1_000_000,
            contentionObserver: { contention.mark() }
        )
        let holder = try await lock.acquire(.exclusive)
        let probe = AdvisoryLockProbe()
        let waiter = Task {
            try await lock.withLock(.exclusive) {
                await probe.enter()
            }
        }

        while !contention.observed { await Task.yield() }
        waiter.cancel()
        do {
            try await waiter.value
            Issue.record("Expected lock acquisition cancellation")
        } catch is CancellationError {
            // Cancellation while polling must not enter the operation.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await probe.entered == false)

        holder.release()
        try await lock.withLock(.exclusive) {}
    }

    @Test("Contention observer reports retries and stays silent without contention")
    func contentionObservation() async throws {
        let url = try lockURL()
        let contention = AdvisoryContentionProbe()
        try await POSIXAdvisoryFileLock(
            url: url,
            contentionObserver: { contention.mark() }
        ).withLock(.shared) {}
        #expect(contention.count == 0)

        let holder = try await POSIXAdvisoryFileLock(url: url).acquire(.exclusive)
        let waiter = Task {
            try await POSIXAdvisoryFileLock(
                url: url,
                retryNanoseconds: 1_000_000,
                contentionObserver: { contention.mark() }
            ).withLock(.exclusive) {}
        }

        while !contention.observed { await Task.yield() }
        let previousContentionCount = contention.count
        while contention.count <= previousContentionCount { await Task.yield() }
        holder.release()
        try await waiter.value
        #expect(contention.count > previousContentionCount)
    }

    @Test("A symlink cannot substitute for a persistent lock file")
    func rejectsSymlink() async throws {
        let url = try lockURL()
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("destination")
        try Data().write(to: destination)
        try FileManager.default.createSymbolicLink(
            at: url,
            withDestinationURL: destination
        )

        await #expect(throws: POSIXAdvisoryFileLock.LockError.self) {
            _ = try await POSIXAdvisoryFileLock(url: url).acquire(.exclusive)
        }
    }

    private func lockURL() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "POSIXAdvisoryFileLockTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("coordination.lock")
    }
}

private actor AdvisoryLockProbe {
    private(set) var entered = false

    func enter() {
        entered = true
    }
}

private final class AdvisoryContentionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    var observed: Bool { count > 0 }

    func mark() {
        lock.withLock { value += 1 }
    }
}
