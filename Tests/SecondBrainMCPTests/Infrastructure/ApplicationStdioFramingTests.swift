import Darwin
import Foundation
import MCP
import Testing
import Synchronization
@testable import second_brain_mcp

@Suite("Application stdio framing", .serialized)
struct ApplicationStdioFramingTests {
    @Test("Concurrent responses retain complete newline-delimited frames under pipe backpressure")
    func concurrentResponsesDoNotInterleave() async throws {
        let pipes = try Pipes()
        defer { pipes.close() }
        try await pipes.transport.connect()
        let responses = try (0..<4).map { index in
            try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": index,
                "result": ["text": String(repeating: String(index), count: 512 * 1_024)],
            ])
        }
        let expectedBytes = responses.reduce(0) { $0 + $1.count + 1 }
        let reader = Task {
            try await Self.read(from: pipes.outputRead, byteCount: expectedBytes)
        }
        let senders = responses.map { response in
            Task { try await pipes.transport.send(response) }
        }
        let readResult = await reader.result
        if case .failure = readResult { senders.forEach { $0.cancel() } }
        var sendFailure: (any Error)?
        for sender in senders {
            if case .failure(let error) = await sender.result { sendFailure = error }
        }
        await pipes.transport.disconnect()
        if let sendFailure { throw sendFailure }
        let received = try readResult.get()
        let frames = received.split(separator: 0x0A).map { Data($0) }
        #expect(frames.count == responses.count)
        var identifiers = Set<Int>()
        for frame in frames {
            let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any]
            let identifier = object?["id"] as? Int
            #expect(identifier != nil, "Each output line must be one intact JSON-RPC response")
            if let identifier, responses.indices.contains(identifier) {
                identifiers.insert(identifier)
                let exactFrame = frame == responses[identifier]
                #expect(exactFrame, "A response frame must contain its original bytes exactly")
            }
        }
        #expect(identifiers == Set(0..<4))
    }

    @Test("Without receive demand the transport does not eagerly drain an arbitrary input backlog")
    func receiveBackpressuresWithoutDemand() async throws {
        let pipes = try Pipes()
        defer { pipes.close() }
        try await pipes.transport.connect()
        let frames = try (0..<16).map { index in
            try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": index, "method": "test",
                "params": ["text": String(repeating: "x", count: 64 * 1_024)],
            ])
        }
        let completion = CompletionProbe()
        let writer = Task {
            for frame in frames {
                var framed = frame
                framed.append(0x0A)
                try await Self.write(framed, to: pipes.inputWrite)
            }
            await completion.finish()
        }
        // This watchdog observes eager draining without any consumer demand.
        // It is not a throughput or latency assertion.
        let drainedWithoutDemand = await completion.finishedBeforeDeadline()
        let receiver = Task {
            let stream = await pipes.transport.receive()
            var iterator = stream.makeAsyncIterator()
            var received: [Data] = []
            for _ in frames {
                guard let frame = try await iterator.next() else { throw PipeFailure.unexpectedEOF }
                received.append(frame)
            }
            return received
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            receiver.cancel()
        }
        let receiveResult = await receiver.result
        watchdog.cancel()
        if case .failure = receiveResult { writer.cancel() }
        let writeResult = await writer.result
        await pipes.transport.disconnect()
        try writeResult.get()
        let received = try receiveResult.get()
        #expect(!drainedWithoutDemand)
        #expect(received.count == frames.count)
        for index in received.indices {
            let exactFrame = received[index] == frames[index]
            #expect(exactFrame, "Backpressure must preserve input framing and order")
        }
    }

    @Test("The wire frame limit accepts exactly the budget and rejects one extra byte across reads")
    func enforcesFrameBudgetAtFragmentedBoundary() async throws {
        let maximum = 64 * 1_024
        for size in [maximum, maximum + 1] {
            let pipes = try Pipes(maximumFrameBytes: maximum)
            defer { pipes.close() }
            try await pipes.transport.connect()
            let payload = Data(repeating: 0x78, count: size)
            let writer = Task {
                var framed = payload
                framed.append(0x0A)
                try await Self.write(framed, to: pipes.inputWrite)
            }
            let receiver = Task {
                let stream = await pipes.transport.receive()
                var iterator = stream.makeAsyncIterator()
                return try await iterator.next()
            }
            let outcome = await receiver.result
            if case .failure = outcome { writer.cancel() }
            _ = await writer.result
            await pipes.transport.disconnect()
            if size == maximum {
                let frame = try outcome.get()
                let exact = frame == payload
                #expect(exact)
            } else {
                guard case .failure(let error) = outcome else {
                    Issue.record("An oversized frame was accepted")
                    continue
                }
                #expect(error as? StdioMessageTransport.Failure == .frameTooLarge)
            }
        }
    }

    @Test("EOF cannot silently discard a partial incoming frame")
    func partialEOFIsAnExplicitFailure() async throws {
        let pipes = try Pipes()
        var inputClosed = false
        defer { pipes.close(inputWriterAlreadyClosed: inputClosed) }
        try await pipes.transport.connect()
        try await Self.write(Data("partial".utf8), to: pipes.inputWrite)
        Darwin.close(pipes.inputWrite)
        inputClosed = true
        let stream = await pipes.transport.receive()
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("A truncated incoming frame must not look like clean EOF")
        } catch {
            #expect(error as? StdioMessageTransport.Failure == .truncatedFrame)
        }
        await pipes.transport.disconnect()
    }

    @Test("Empty lines, coalesced frames, and clean EOF preserve exact input order")
    func coalescedFramesAndCleanEOF() async throws {
        let pipes = try Pipes()
        var inputClosed = false
        defer { pipes.close(inputWriterAlreadyClosed: inputClosed) }
        try await pipes.transport.connect()
        try await Self.write(Data("\nfirst\nsecond\n".utf8), to: pipes.inputWrite)
        Darwin.close(pipes.inputWrite)
        inputClosed = true
        var frames: [Data] = []
        for try await frame in await pipes.transport.receive() { frames.append(frame) }
        #expect(frames == [Data("first".utf8), Data("second".utf8)])
        await pipes.transport.disconnect()
    }

    @Test("Disconnect ends pending receive demand and stdio cannot reconnect after closure")
    func disconnectIsTerminal() async throws {
        let pipes = try Pipes()
        defer { pipes.close() }
        try await pipes.transport.connect()
        let receiver = Task {
            let stream = await pipes.transport.receive()
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        await pipes.transport.disconnect()
        let received = try await receiver.value
        #expect(received == nil)
        await #expect(throws: StdioMessageTransport.Failure.closed) {
            try await pipes.transport.connect()
        }
    }

    @Test("Cancelling a queued response writes no bytes and does not interrupt the active frame")
    func queuedSendCancellationPreservesActiveFrame() async throws {
        let pipes = try Pipes()
        defer { pipes.close() }
        try await pipes.transport.connect()
        let payload = Data(repeating: 0x78, count: 2 * 1_024 * 1_024)
        let active = Task { try await pipes.transport.send(payload) }
        let prefix = try await Self.read(from: pipes.outputRead, byteCount: 1)
        let queued = Task { try await pipes.transport.send(Data("cancelled-marker".utf8)) }
        let didQueue = await waitForSendQueue(pipes.transport, count: 1)
        queued.cancel()
        let cancelled = await queued.result
        let tail = try await Self.read(from: pipes.outputRead, byteCount: payload.count)
        try await active.value
        await pipes.transport.disconnect()
        #expect(didQueue)
        guard case .failure(let error) = cancelled else {
            Issue.record("The queued sender did not observe cancellation")
            return
        }
        #expect(error is CancellationError)
        var actual = prefix
        actual.append(tail)
        var expected = payload
        expected.append(0x0A)
        let exact = actual == expected
        #expect(exact, "Queued cancellation must not emit a partial or extra response")
    }

    @Test("Cancelling a partially emitted frame terminates both transport directions")
    func activeSendCancellationIsTerminal() async throws {
        let pipes = try Pipes()
        defer { pipes.close() }
        try await pipes.transport.connect()
        let active = Task {
            try await pipes.transport.send(Data(repeating: 0x78, count: 2 * 1_024 * 1_024))
        }
        _ = try await Self.read(from: pipes.outputRead, byteCount: 1)
        active.cancel()
        let result = await active.result
        guard case .failure(let error) = result else {
            Issue.record("The partially emitted response ignored cancellation")
            return
        }
        #expect(error is CancellationError)
        let stream = await pipes.transport.receive()
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == nil)
        await #expect(throws: StdioMessageTransport.Failure.closed) {
            try await pipes.transport.send(Data("later".utf8))
        }
        await pipes.transport.disconnect()
    }

    @Test("Disconnect releases an active response and its queued sender")
    func disconnectReleasesQueuedSenders() async throws {
        let pipes = try Pipes()
        defer { pipes.close() }
        try await pipes.transport.connect()
        let active = Task {
            try await pipes.transport.send(Data(repeating: 0x78, count: 2 * 1_024 * 1_024))
        }
        _ = try await Self.read(from: pipes.outputRead, byteCount: 1)
        let queued = Task { try await pipes.transport.send(Data("queued".utf8)) }
        let didQueue = await waitForSendQueue(pipes.transport, count: 1)
        await pipes.transport.disconnect()
        for result in [await active.result, await queued.result] {
            guard case .failure(let error) = result else {
                Issue.record("Disconnected output unexpectedly succeeded")
                continue
            }
            #expect(error as? StdioMessageTransport.Failure == .closed)
        }
        #expect(didQueue)
        #expect(await pipes.transport.waitingSenderCount == 0)
    }

    @Test("A closed output pipe reports failure without SIGPIPE termination")
    func closedOutputPipeIsTerminal() async throws {
        let pipes = try Pipes()
        var outputClosed = false
        defer { pipes.close(outputReaderAlreadyClosed: outputClosed) }
        try await pipes.transport.connect()
        Darwin.close(pipes.outputRead)
        outputClosed = true
        await #expect(throws: StdioMessageTransport.Failure.io) {
            try await pipes.transport.send(Data("response".utf8))
        }
        let stream = await pipes.transport.receive()
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == nil)
        await pipes.transport.disconnect()
    }

    @Test("The actual MCP SDK completes concurrent tool calls over the app-owned pipe transport")
    func sdkServerCompletesConcurrentCalls() async throws {
        let pipes = try Pipes()
        defer { pipes.close() }
        let server = Server(
            name: "Stdio framing fixture", version: "1",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(CallTool.self) { params in
            let slot = params.arguments?["slot"]?.intValue ?? -1
            return CallTool.Result(content: [
                .text(text: String(repeating: String(slot), count: 512 * 1_024),
                      annotations: nil, _meta: nil),
            ])
        }
        try await server.start(transport: pipes.transport)
        let client = Client(name: "Stdio fixture client", version: "1")
        let clientTransport = StdioTransport(
            input: .init(rawValue: pipes.outputRead), output: .init(rawValue: pipes.inputWrite)
        )
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            await client.disconnect()
            await server.stop()
        }
        do {
            _ = try await client.connect(transport: clientTransport)
            let calls = (0..<4).map { slot in
                Task {
                    try await client.callTool(name: "fixture", arguments: ["slot": .int(slot)])
                }
            }
            var failure: (any Error)?
            for (slot, call) in calls.enumerated() {
                do {
                    let response = try await call.value
                    let texts = response.content.compactMap { item -> String? in
                        if case .text(let text, _, _) = item { return text }
                        return nil
                    }
                    let exact = texts == [String(repeating: String(slot), count: 512 * 1_024)]
                    #expect(exact)
                } catch { failure = error }
            }
            if let failure { throw failure }
        } catch {
            watchdog.cancel()
            await client.disconnect()
            await server.stop()
            throw error
        }
        watchdog.cancel()
        await client.disconnect()
        await server.stop()
    }

    @Test("An idle pending receive waits for readiness instead of repeatedly retrying read")
    func idleReadDoesNotPoll() async throws {
        let probe = IOBlockedProbe()
        let pipes = try Pipes(blockedIOObserver: probe.record)
        defer { pipes.close() }
        try await pipes.transport.connect()
        let receiver = Task {
            var iterator = await pipes.transport.receive().makeAsyncIterator()
            return try await iterator.next()
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            receiver.cancel()
        }
        defer { watchdog.cancel() }
        let entered = await probe.waitForFirst(.input)
        // Observe redundant work while no bytes exist, not a response-time threshold.
        try await Task.sleep(for: .milliseconds(100))
        let idleAttempts = probe.count(.input)
        do {
            try await Self.write(Data("ready\n".utf8), to: pipes.inputWrite)
        } catch {
            receiver.cancel()
            _ = await receiver.result
            await pipes.transport.disconnect()
            throw error
        }
        let received = await receiver.result
        await pipes.transport.disconnect()
        #expect(entered)
        #expect(idleAttempts == 1, "No second read is useful until descriptor readiness changes")
        #expect(try received.get() == Data("ready".utf8))
    }

    @Test("A full output pipe waits for readiness instead of repeatedly retrying write")
    func blockedWriteDoesNotPoll() async throws {
        let probe = IOBlockedProbe()
        let pipes = try Pipes(blockedIOObserver: probe.record)
        defer { pipes.close() }
        try await pipes.transport.connect()
        let payload = Data(repeating: 0x78, count: 256 * 1_024)
        let sender = Task { try await pipes.transport.send(payload) }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            sender.cancel()
        }
        defer { watchdog.cancel() }
        let entered = await probe.waitForFirst(.output)
        try await Task.sleep(for: .milliseconds(100))
        let idleAttempts = probe.count(.output)
        let received: Data
        do {
            received = try await Self.read(from: pipes.outputRead, byteCount: payload.count + 1)
        } catch {
            sender.cancel()
            _ = await sender.result
            await pipes.transport.disconnect()
            throw error
        }
        let result = await sender.result
        await pipes.transport.disconnect()
        try result.get()
        #expect(entered)
        #expect(idleAttempts == 1, "No second write is useful until pipe capacity changes")
        var expected = payload
        expected.append(0x0A)
        #expect(received == expected)
    }

    private final class IOBlockedProbe: Sendable {
        private let counts = Mutex((input: 0, output: 0))

        func record(_ direction: StdioMessageTransport.IODirection) {
            counts.withLock {
                switch direction {
                case .input: $0.input += 1
                case .output: $0.output += 1
                }
            }
        }

        func count(_ direction: StdioMessageTransport.IODirection) -> Int {
            counts.withLock {
                switch direction {
                case .input: $0.input
                case .output: $0.output
                }
            }
        }

        func waitForFirst(_ direction: StdioMessageTransport.IODirection) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while count(direction) == 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            return count(direction) > 0
        }
    }

    private func waitForSendQueue(_ transport: StdioMessageTransport, count: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await transport.waitingSenderCount < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await transport.waitingSenderCount == count
    }

    private struct Pipes: Sendable {
        let inputRead: Int32
        let inputWrite: Int32
        let outputRead: Int32
        let outputWrite: Int32
        let transport: StdioMessageTransport

        init(
            maximumFrameBytes: Int = 192 * 1_024 * 1_024,
            blockedIOObserver: (@Sendable (StdioMessageTransport.IODirection) -> Void)? = nil
        ) throws {
            var input: [Int32] = [-1, -1]
            var output: [Int32] = [-1, -1]
            guard Darwin.pipe(&input) == 0 else { throw PipeFailure.io }
            guard Darwin.pipe(&output) == 0 else {
                Darwin.close(input[0])
                Darwin.close(input[1])
                throw PipeFailure.io
            }
            inputRead = input[0]
            inputWrite = input[1]
            outputRead = output[0]
            outputWrite = output[1]
            transport = StdioMessageTransport(
                input: input[0], output: output[1], maximumFrameBytes: maximumFrameBytes,
                blockedIOObserver: blockedIOObserver
            )
            guard fcntl(inputWrite, F_SETFL, fcntl(inputWrite, F_GETFL) | O_NONBLOCK) == 0,
                  fcntl(outputRead, F_SETFL, fcntl(outputRead, F_GETFL) | O_NONBLOCK) == 0 else {
                close()
                throw PipeFailure.io
            }
        }

        func close(inputWriterAlreadyClosed: Bool = false, outputReaderAlreadyClosed: Bool = false) {
            Darwin.close(inputRead)
            if !inputWriterAlreadyClosed { Darwin.close(inputWrite) }
            if !outputReaderAlreadyClosed { Darwin.close(outputRead) }
            Darwin.close(outputWrite)
        }
    }

    private static func read(from descriptor: Int32, byteCount: Int) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while result.count < byteCount {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw PipeFailure.timeout }
            let maximumRead = min(buffer.count, byteCount - result.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, maximumRead)
            }
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                throw PipeFailure.unexpectedEOF
            } else if errno != EAGAIN && errno != EINTR {
                throw PipeFailure.io
            }
            // Force real pipe backpressure; correctness must not depend on reader speed.
            try await Task.sleep(for: .milliseconds(1))
        }
        return result
    }

    private static func write(_ data: Data, to descriptor: Int32) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw PipeFailure.timeout }
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno != EAGAIN && errno != EINTR {
                throw PipeFailure.io
            } else {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    private actor CompletionProbe {
        private var finished = false
        func finish() { finished = true }

        func finishedBeforeDeadline() async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !finished, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return finished
        }
    }

    private enum PipeFailure: Error { case io, timeout, unexpectedEOF }
}
