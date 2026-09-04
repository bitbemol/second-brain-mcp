import Testing
@testable import second_brain_mcp

@Suite("MCP startup recovery task")
struct MCPStartupRecoveryTaskTests {
    @Test("A failed startup recovery is attempted only once")
    func failureIsNotRetried() async {
        let owner = MCPStartupRecoveryTask()
        let recovery = FailingRecovery()
        let task = await owner.install { try await recovery.run() }

        await task.value

        #expect(await recovery.attempts == 1)
        await owner.shutdown()
    }

    @Test("Shutdown cancels and joins active startup recovery")
    func shutdownCancelsAndJoins() async {
        let owner = MCPStartupRecoveryTask()
        let recovery = RecoveryHold()
        _ = await owner.install { try await recovery.run() }
        await recovery.waitUntilEntered()

        await owner.shutdown()

        #expect(await recovery.cancelledAndFinished)
    }

    private actor FailingRecovery {
        struct ExpectedFailure: Error {}
        private(set) var attempts = 0

        func run() throws {
            attempts += 1
            throw ExpectedFailure()
        }
    }

    private actor RecoveryHold {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var continuation: CheckedContinuation<Void, Error>?
        private(set) var cancelledAndFinished = false

        func run() async throws {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            defer { cancelledAndFinished = true }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation = $0 }
            } onCancel: {
                Task { await self.cancel() }
            }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        private func cancel() {
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }
    }
}
