import Dispatch
import Synchronization

/// One demand-owned readiness registration. Handlers only signal; the transport
/// retains responsibility for I/O and never gives ownership of its borrowed fd away.
// DispatchSourceProtocol lacks Sendable. Its immutable source is configured before
// activation; subsequent cancel calls are thread-safe, and all mutable state is locked.
final class StdioDescriptorReadiness: @unchecked Sendable {
    private enum Outcome: Sendable { case ready, cancelled }

    private struct State {
        var outcome: Outcome?
        var ownerInstalled = false
        var owner: CheckedContinuation<Void, any Error>?
        var stopped = false
        var stopWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    private let source: any DispatchSourceProtocol

    init(descriptor: Int32, direction: StdioMessageTransport.IODirection) {
        switch direction {
        case .input:
            source = DispatchSource.makeReadSource(
                fileDescriptor: descriptor, queue: .global(qos: .userInitiated)
            )
        case .output:
            source = DispatchSource.makeWriteSource(
                fileDescriptor: descriptor, queue: .global(qos: .userInitiated)
            )
        }
        source.setEventHandler { [weak self] in self?.resolve(.ready) }
        source.setCancelHandler { [weak self] in self?.didStop() }
        // Activate exactly once, including when readiness/cancellation wins before
        // wait() installs its continuation. No suspended source survives cleanup.
        source.activate()
    }

    deinit { source.cancel() }

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let completed = state.withLock { state -> Outcome? in
                    precondition(!state.ownerInstalled)
                    state.ownerInstalled = true
                    if state.stopped { return state.outcome }
                    state.owner = continuation
                    return nil
                }
                if let completed { Self.resume(continuation, with: completed) }
            }
            try Task.checkCancellation()
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() { resolve(.cancelled) }

    /// The descriptor owner may close/reuse its fd only after cancellation has
    /// unregistered the source. Multiple terminal paths may await this same signal.
    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            let stopped = state.withLock { state in
                if state.stopped { return true }
                state.stopWaiters.append(continuation)
                return false
            }
            if stopped { continuation.resume() }
        }
    }

    private func resolve(_ outcome: Outcome) {
        let won = state.withLock { state in
            guard state.outcome == nil else { return false }
            state.outcome = outcome
            return true
        }
        if won { source.cancel() }
    }

    private func didStop() {
        let completion = state.withLock { state in
            state.stopped = true
            let completion = (state.outcome ?? .cancelled, state.owner, state.stopWaiters)
            state.owner = nil
            state.stopWaiters.removeAll()
            return completion
        }
        if let owner = completion.1 { Self.resume(owner, with: completion.0) }
        for waiter in completion.2 { waiter.resume() }
    }

    private static func resume(
        _ continuation: CheckedContinuation<Void, any Error>, with outcome: Outcome
    ) {
        switch outcome {
        case .ready: continuation.resume()
        case .cancelled: continuation.resume(throwing: CancellationError())
        }
    }
}
