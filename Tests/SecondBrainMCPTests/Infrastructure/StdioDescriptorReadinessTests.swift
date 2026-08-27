import Darwin
import Foundation
import Synchronization
import Testing
@testable import second_brain_mcp

@Suite("Stdio readiness lifetime", .serialized)
struct StdioDescriptorReadinessTests {
    @Test("Cancellation before owner installation is remembered after source shutdown")
    func cancellationBeforeWait() async throws {
        let pipe = try PipePair()
        defer { pipe.close() }
        let readiness = StdioDescriptorReadiness(descriptor: pipe.reader, direction: .input)
        readiness.cancel()
        await readiness.waitUntilStopped()
        await #expect(throws: CancellationError.self) { try await readiness.wait() }
        #expect(fcntl(pipe.reader, F_GETFD) >= 0)
    }

    @Test("An already-cancelled task releases its newly registered readiness source")
    func taskCancelledBeforeWait() async throws {
        let pipe = try PipePair()
        defer { pipe.close() }
        let readiness = StdioDescriptorReadiness(descriptor: pipe.reader, direction: .input)
        let owner = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await readiness.wait()
        }
        let result = await owner.result
        await readiness.waitUntilStopped()
        guard case .failure(let error) = result else {
            Issue.record("A pre-cancelled task unexpectedly succeeded")
            return
        }
        #expect(error is CancellationError)
        #expect(fcntl(pipe.reader, F_GETFD) >= 0)
    }

    @Test("Readiness before owner installation is remembered without consuming input")
    func readinessBeforeWait() async throws {
        let pipe = try PipePair()
        defer { pipe.close() }
        try Self.writeByte(0x61, to: pipe.writer)
        let readiness = StdioDescriptorReadiness(descriptor: pipe.reader, direction: .input)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            readiness.cancel()
        }
        defer { watchdog.cancel() }
        // This completes only after the event won and its source was unregistered.
        await readiness.waitUntilStopped()
        try await readiness.wait()
        #expect(try Self.readByte(from: pipe.reader) == 0x61)
    }

    @Test("Ready versus cancellation races complete once and preserve borrowed descriptors")
    func readinessCancellationRace() async throws {
        for iteration in 0..<64 {
            let pipe = try PipePair()
            defer { pipe.close() }
            let readiness = StdioDescriptorReadiness(descriptor: pipe.reader, direction: .input)
            let owner = Task { try await readiness.wait() }
            let signal = Task { try Self.writeByte(UInt8(iteration), to: pipe.writer) }
            let cancellation = Task { readiness.cancel() }
            let watchdog = Task {
                try await Task.sleep(for: .seconds(5))
                owner.cancel()
                readiness.cancel()
            }
            defer { watchdog.cancel() }
            try await signal.value
            await cancellation.value
            let result = await owner.result
            await readiness.waitUntilStopped()
            if case .failure(let error) = result {
                #expect(error is CancellationError)
            }
            #expect(fcntl(pipe.reader, F_GETFD) >= 0)
            #expect(try Self.readByte(from: pipe.reader) == UInt8(iteration))
        }
    }

    @Test("Disconnect quiesces simultaneous read/write waits before borrowed fd close and reuse")
    func disconnectQuiescesBothDirectionsBeforeDescriptorReuse() async throws {
        let input = try PipePair()
        defer { input.close() }
        let output = try PipePair()
        defer { output.close() }
        let replacementInput = try PipePair()
        defer { replacementInput.close() }
        let replacementOutput = try PipePair()
        defer { replacementOutput.close() }
        let probe = BlockedDirections()
        let transport = StdioMessageTransport(
            input: input.reader, output: output.writer, blockedIOObserver: probe.record
        )
        try await transport.connect()
        let receiver = Task {
            var iterator = await transport.receive().makeAsyncIterator()
            return try await iterator.next()
        }
        let sender = Task {
            try await transport.send(Data(repeating: 0x78, count: 2 * 1_024 * 1_024))
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            receiver.cancel()
            sender.cancel()
            await transport.disconnect()
        }
        defer { watchdog.cancel() }
        let bothBlocked = await probe.waitForBoth()
        await transport.disconnect()
        #expect(bothBlocked)
        #expect(fcntl(input.reader, F_GETFD) >= 0, "Disconnect must not close borrowed input")
        #expect(fcntl(output.writer, F_GETFD) >= 0, "Disconnect must not close borrowed output")

        // dup2 atomically closes and reuses only this fixture's still-owned fd numbers.
        // Rebind before awaiting old task completion, exercising the quiescence promise.
        let inputRebound = dup2(replacementInput.reader, input.reader) == input.reader
        let outputRebound = dup2(replacementOutput.writer, output.writer) == output.writer
        // Make the reused descriptors ready before old tasks finish, exposing any
        // stale callback or I/O continuation that escaped disconnect's quiescence.
        try Self.writeByte(0x49, to: replacementInput.writer)
        try Self.writeByte(0x4F, to: output.writer)
        let received = await receiver.result
        let sent = await sender.result
        try #require(inputRebound && outputRebound)
        #expect(try received.get() == nil)
        guard case .failure(let error) = sent else {
            Issue.record("The disconnected blocked send unexpectedly completed")
            return
        }
        #expect(error as? StdioMessageTransport.Failure == .closed)

        // An old readiness callback or resumed I/O must not consume or contaminate
        // either new pipe. The replacement remains usable after all old tasks finish.
        #expect(try Self.readByte(from: input.reader) == 0x49)
        #expect(try Self.readByte(from: replacementOutput.reader) == 0x4F)
        #expect(Self.isEmpty(replacementOutput.reader))
        await #expect(throws: StdioMessageTransport.Failure.closed) {
            try await transport.send(Data("must-not-be-written".utf8))
        }
        #expect(Self.isEmpty(replacementOutput.reader))
    }

    private final class BlockedDirections: Sendable {
        private let seen = Mutex((input: false, output: false))

        func record(_ direction: StdioMessageTransport.IODirection) {
            seen.withLock {
                switch direction {
                case .input: $0.input = true
                case .output: $0.output = true
                }
            }
        }

        func waitForBoth() async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < deadline {
                if seen.withLock({ $0.input && $0.output }) { return true }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return seen.withLock { $0.input && $0.output }
        }
    }

    private struct PipePair: Sendable {
        let reader: Int32
        let writer: Int32

        init() throws {
            var descriptors: [Int32] = [-1, -1]
            guard Darwin.pipe(&descriptors) == 0 else { throw PipeFailure.io }
            reader = descriptors[0]
            writer = descriptors[1]
            for descriptor in descriptors {
                let flags = fcntl(descriptor, F_GETFL)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    close()
                    throw PipeFailure.io
                }
            }
        }

        func close() {
            Darwin.close(reader)
            Darwin.close(writer)
        }
    }

    private static func writeByte(_ value: UInt8, to descriptor: Int32) throws {
        var value = value
        var count: Int
        repeat { count = Darwin.write(descriptor, &value, 1) } while count < 0 && errno == EINTR
        guard count == 1 else { throw PipeFailure.io }
    }

    private static func readByte(from descriptor: Int32) throws -> UInt8 {
        var value: UInt8 = 0
        var count: Int
        repeat { count = Darwin.read(descriptor, &value, 1) } while count < 0 && errno == EINTR
        guard count == 1 else { throw PipeFailure.io }
        return value
    }

    private static func isEmpty(_ descriptor: Int32) -> Bool {
        var value: UInt8 = 0
        let count = Darwin.read(descriptor, &value, 1)
        return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
    }

    private enum PipeFailure: Error { case io }
}
