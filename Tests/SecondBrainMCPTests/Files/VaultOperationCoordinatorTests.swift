import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Vault operation coordinator tree moves` {
    @Test
    func `A directory move excludes note reads until the subtree rename completes`() async throws {
        let root = NSTemporaryDirectory() + "VaultOperationCoordinatorTests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        try "safe".write(
            toFile: root + "/notes/a.md",
            atomically: true,
            encoding: .utf8
        )
        let locks = URL(fileURLWithPath: root).appendingPathComponent("locks")
        try FileManager.default.createDirectory(
            at: locks.appendingPathComponent("paths", isDirectory: true),
            withIntermediateDirectories: true
        )
        let coordinator = VaultOperationCoordinator(lockDirectoryURL: locks)
        let target = try ReadableFileTarget.resolve(
            path: "notes/a.md",
            format: .markdown,
            vaultPath: root
        )
        let hold = TreeMoveHold()
        let read = TreeMoveReadProbe()

        let writer = Task {
            try await coordinator.withTreeWrite {
                await hold.enterAndWait()
            }
        }
        await hold.waitUntilEntered()
        let reader = Task {
            try await coordinator.withRead(target: target) {
                await read.markEntered()
            }
        }
        while await coordinator.waitingTreeOperationCount == 0 {
            await Task.yield()
        }
        #expect(await read.entered == false)

        await hold.release()
        try await writer.value
        try await reader.value
        #expect(await read.entered)
    }

    @Test
    func `Cross-process path lock storage remains bounded under path churn`() async throws {
        let root = NSTemporaryDirectory()
            + "VaultOperationCoordinatorStripeTests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        let locks = URL(fileURLWithPath: root).appendingPathComponent("locks")
        let paths = locks.appendingPathComponent("paths", isDirectory: true)
        try FileManager.default.createDirectory(
            at: paths,
            withIntermediateDirectories: true
        )
        let coordinator = VaultOperationCoordinator(
            lockDirectoryURL: locks,
            pathLockStripeCount: 4
        )

        for index in 0..<100 {
            let relative = "notes/generated-\(index).md"
            try "safe".write(
                toFile: root + "/" + relative,
                atomically: true,
                encoding: .utf8
            )
            let target = try ReadableFileTarget.resolve(
                path: relative,
                format: .markdown,
                vaultPath: root
            )
            try await coordinator.withRead(target: target) {}
        }

        let lockFiles = try FileManager.default.contentsOfDirectory(
            atPath: paths.path
        )
        #expect(lockFiles.count <= 8)
        #expect(lockFiles.allSatisfy {
            $0.hasPrefix("stripe-")
                && ($0.hasSuffix(".queue") || $0.hasSuffix(".resource"))
        })
    }

    @Test
    func `An externally held stripe cannot create unbounded active operations`() async throws {
        let fixture = try VaultCoordinatorFixture(fileCount: 5)
        defer { fixture.remove() }
        let coordinator = VaultOperationCoordinator(
            lockDirectoryURL: fixture.locks,
            pathLockStripeCount: 1,
            maximumConcurrentReaders: 2,
            maximumWaitersPerPath: 2,
            maximumTotalWaiters: 2
        )
        let externalStripe = POSIXAdvisoryFileLock(
            url: fixture.paths.appendingPathComponent("stripe-0000.queue")
        )
        let stripeLease = try await externalStripe.acquire(.exclusive)

        let operations = fixture.readableTargets.prefix(4).map { target in
            Task { try await coordinator.withRead(target: target) {} }
        }
        while await coordinator.waitingTreeOperationCount != 2 {
            await Task.yield()
        }

        do {
            try await coordinator.withRead(target: fixture.readableTargets[4]) {}
            Issue.record("Expected a bounded-capacity rejection")
        } catch let error as VaultOperationCoordinator.CapacityExceeded {
            #expect(error.description ==
                "Vault file operations are at capacity; retry after an active operation finishes")
        } catch {
            Issue.record("Unexpected capacity error: \(error)")
        }

        stripeLease.release()
        for operation in operations {
            try await operation.value
        }
        #expect(await coordinator.waitingTreeOperationCount == 0)
    }

    @Test
    func `Two coordinator instances exclude writes to the same path`() async throws {
        let fixture = try VaultCoordinatorFixture(fileCount: 1)
        defer { fixture.remove() }
        let contention = VaultLockContentionProbe()
        let firstCoordinator = VaultOperationCoordinator(lockDirectoryURL: fixture.locks)
        let secondCoordinator = VaultOperationCoordinator(
            lockDirectoryURL: fixture.locks,
            contentionObserver: { contention.record() }
        )
        let hold = TreeMoveHold()
        let secondEntry = TreeMoveReadProbe()
        let target = fixture.writableTargets[0]

        let first = Task {
            try await firstCoordinator.withWrite(target: target) {
                await hold.enterAndWait()
            }
        }
        await hold.waitUntilEntered()
        let second = Task {
            try await secondCoordinator.withWrite(target: target) {
                await secondEntry.markEntered()
            }
        }
        await contention.waitUntilObserved()
        #expect(await secondEntry.entered == false)

        await hold.release()
        try await first.value
        try await second.value
        #expect(await secondEntry.entered)
    }

    @Test
    func `A tree writer excludes another coordinator's note reader`() async throws {
        let fixture = try VaultCoordinatorFixture(fileCount: 1)
        defer { fixture.remove() }
        let contention = VaultLockContentionProbe()
        let writerCoordinator = VaultOperationCoordinator(lockDirectoryURL: fixture.locks)
        let readerCoordinator = VaultOperationCoordinator(
            lockDirectoryURL: fixture.locks,
            contentionObserver: { contention.record() }
        )
        let hold = TreeMoveHold()
        let readEntry = TreeMoveReadProbe()

        let writer = Task {
            try await writerCoordinator.withTreeWrite {
                await hold.enterAndWait()
            }
        }
        await hold.waitUntilEntered()
        let reader = Task {
            try await readerCoordinator.withRead(target: fixture.readableTargets[0]) {
                await readEntry.markEntered()
            }
        }
        await contention.waitUntilObserved()
        #expect(await readEntry.entered == false)

        await hold.release()
        try await writer.value
        try await reader.value
        #expect(await readEntry.entered)
    }

    @Test
    func `Distinct paths sharing one stripe exclude across coordinators`() async throws {
        let fixture = try VaultCoordinatorFixture(fileCount: 2)
        defer { fixture.remove() }
        let contention = VaultLockContentionProbe()
        let firstCoordinator = VaultOperationCoordinator(
            lockDirectoryURL: fixture.locks,
            pathLockStripeCount: 1
        )
        let secondCoordinator = VaultOperationCoordinator(
            lockDirectoryURL: fixture.locks,
            pathLockStripeCount: 1,
            contentionObserver: { contention.record() }
        )
        let hold = TreeMoveHold()
        let secondEntry = TreeMoveReadProbe()

        let first = Task {
            try await firstCoordinator.withWrite(target: fixture.writableTargets[0]) {
                await hold.enterAndWait()
            }
        }
        await hold.waitUntilEntered()
        let second = Task {
            try await secondCoordinator.withWrite(target: fixture.writableTargets[1]) {
                await secondEntry.markEntered()
            }
        }
        await contention.waitUntilObserved()
        #expect(await secondEntry.entered == false)

        await hold.release()
        try await first.value
        try await second.value
        #expect(await secondEntry.entered)
    }
}

private struct VaultCoordinatorFixture {
    let root: String
    let locks: URL
    let paths: URL
    let readableTargets: [ReadableFileTarget]
    let writableTargets: [WritableFileTarget]

    init(fileCount: Int) throws {
        root = NSTemporaryDirectory() + "VaultCoordinatorFixture-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        locks = URL(fileURLWithPath: root).appendingPathComponent("locks")
        paths = locks.appendingPathComponent("paths", isDirectory: true)
        try FileManager.default.createDirectory(at: paths, withIntermediateDirectories: true)

        var readable: [ReadableFileTarget] = []
        var writable: [WritableFileTarget] = []
        for index in 0..<fileCount {
            let relative = "notes/file-\(index).md"
            try "safe".write(
                toFile: root + "/" + relative,
                atomically: true,
                encoding: .utf8
            )
            readable.append(try ReadableFileTarget.resolve(
                path: relative,
                format: .markdown,
                vaultPath: root
            ))
            writable.append(try WritableFileTarget.resolve(
                path: relative,
                format: .markdown,
                vaultPath: root
            ))
        }
        readableTargets = readable
        writableTargets = writable
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

private final class VaultLockContentionProbe: @unchecked Sendable {
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

private actor TreeMoveHold {
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

private actor TreeMoveReadProbe {
    private(set) var entered = false
    func markEntered() { entered = true }
}
