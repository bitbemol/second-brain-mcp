import Foundation
import Testing
@testable import second_brain_mcp

@Suite("MCP startup recovery cancellation")
struct MCPStartupRecoveryGateTests {
    @Test("A later mutation retries recovery after a transient failure")
    func retriesAfterFailure() async throws {
        let gate = MCPStartupRecoveryGate()
        let recovery = FailOnceRecovery()
        let initial = await gate.install { try await recovery.run() }

        await #expect(throws: FailOnceRecovery.ExpectedFailure.self) {
            try await initial.value
        }
        try await gate.wait()

        #expect(await recovery.attempts == 2)
    }

    @Test("A cancelled caller does not wait for recovery installation")
    func cancelsBeforeRecoveryInstallation() async throws {
        try await checkCancellation(recoveryInstalled: false)
    }

    @Test("A cancelled caller does not wait for pending shared recovery")
    func cancelsWhileRecoveryIsPending() async throws {
        try await checkCancellation(recoveryInstalled: true)
    }

    @Test("Shutdown cancels and joins an active recovery retry")
    func shutdownCancelsAndJoinsRetry() async throws {
        let gate = MCPStartupRecoveryGate()
        let recovery = FailThenHoldRecovery()
        let initial = await gate.install { try await recovery.run() }
        await #expect(throws: FailThenHoldRecovery.ExpectedFailure.self) {
            try await initial.value
        }
        let waiter = Task { try await gate.wait() }
        await recovery.waitUntilRetryEntered()

        await gate.shutdown()
        let retryFinishedBeforeManualRelease = await recovery.retryFinished

        // Makes the broken implementation terminate instead of leaving a task
        // behind after recording the red expectation.
        await recovery.releaseRetry()
        _ = await waiter.result
        #expect(retryFinishedBeforeManualRelease)
    }

    private func checkCancellation(recoveryInstalled: Bool) async throws {
        let gate = MCPStartupRecoveryGate()
        let hold = RecoveryHold()
        let probe = CompletionProbe()
        var recovery: Task<Void, Error>?
        if recoveryInstalled {
            recovery = await gate.install { await hold.run() }
        }
        let waiter = Task {
            await probe.markStarted()
            do {
                try await gate.wait()
                await probe.finish(cancelled: false)
            } catch is CancellationError {
                await probe.finish(cancelled: true)
            } catch {
                await probe.finish(cancelled: false)
            }
        }
        await probe.waitUntilStarted()
        waiter.cancel()
        // A watchdog prevents the broken implementation from hanging the test.
        // The assertion is completion before releasing recovery, not a latency SLO.
        let cancelledBeforeRelease = await probe.cancelledBeforeDeadline()
        if recovery == nil {
            recovery = await gate.install { await hold.run() }
        }
        await hold.release()
        try await recovery?.value
        _ = await waiter.result
        try await gate.wait()
        #expect(cancelledBeforeRelease)
    }

    private actor RecoveryHold {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func run() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private actor FailOnceRecovery {
        struct ExpectedFailure: Error {}

        private(set) var attempts = 0

        func run() throws {
            attempts += 1
            if attempts == 1 {
                throw ExpectedFailure()
            }
        }
    }

    private actor FailThenHoldRecovery {
        struct ExpectedFailure: Error {}

        private var attempts = 0
        private var retryEntered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var retryContinuation: CheckedContinuation<Void, Error>?
        private(set) var retryFinished = false

        func run() async throws {
            attempts += 1
            if attempts == 1 { throw ExpectedFailure() }
            retryEntered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            defer { retryFinished = true }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { retryContinuation = $0 }
            } onCancel: {
                Task { await self.cancelRetry() }
            }
        }

        func waitUntilRetryEntered() async {
            guard !retryEntered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func releaseRetry() {
            retryContinuation?.resume()
            retryContinuation = nil
        }

        private func cancelRetry() {
            retryContinuation?.resume(throwing: CancellationError())
            retryContinuation = nil
        }
    }

    private actor CompletionProbe {
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var cancelled: Bool?

        func markStarted() {
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func finish(cancelled: Bool) {
            self.cancelled = cancelled
        }

        func cancelledBeforeDeadline() async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            while cancelled == nil, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return cancelled == true
        }
    }
}
