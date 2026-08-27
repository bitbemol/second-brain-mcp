import Darwin
import Foundation
import Logging
import MCP

/// One-shot newline-delimited stdio transport with demand-driven reads and atomic response frames.
/// Descriptors are borrowed. Connecting enables nonblocking I/O on their shared file descriptions.
actor StdioMessageTransport: Transport {
    nonisolated let logger = Logger(
        label: "second-brain-mcp.stdio", factory: { _ in SwiftLogNoOpLogHandler() }
    )

    private enum State { case idle, connected, closed }
    static let defaultMaximumFrameBytes = 192 * 1_024 * 1_024

    private let input: Int32
    private let output: Int32
    enum IODirection: Sendable { case input, output }
    private let blockedIOObserver: (@Sendable (IODirection) -> Void)?
    private let maximumFrameBytes: Int
    private let outputGate = AsyncExclusiveGate(maximumWaiters: 32)
    private var state = State.idle
    private var receiveClaimed = false
    private var reading = false
    private var inputReadiness: StdioDescriptorReadiness?
    private var outputReadiness: StdioDescriptorReadiness?
    private var chunk = Data()
    private var chunkOffset = 0
    private let chunkBytes = 64 * 1_024

    init(
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        maximumFrameBytes: Int = StdioMessageTransport.defaultMaximumFrameBytes,
        blockedIOObserver: (@Sendable (IODirection) -> Void)? = nil
    ) {
        self.input = input
        self.output = output
        self.maximumFrameBytes = maximumFrameBytes
        self.blockedIOObserver = blockedIOObserver
    }

    func connect() async throws {
        switch state {
        case .connected: return
        case .closed: throw Failure.closed
        case .idle: break
        }
        try makeNonblocking(input)
        try makeNonblocking(output)
        guard fcntl(output, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.io }
        state = .connected
    }

    func disconnect() async {
        state = .closed
        chunk = Data()
        chunkOffset = 0
        let inputWait = inputReadiness
        let outputWait = outputReadiness
        inputWait?.cancel()
        outputWait?.cancel()
        await inputWait?.waitUntilStopped()
        await outputWait?.waitUntilStopped()
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        guard !receiveClaimed else {
            return AsyncThrowingStream { $0.finish(throwing: Failure.multipleConsumers) }
        }
        receiveClaimed = true
        return AsyncThrowingStream(unfolding: { try await self.nextFrame() })
    }

    /// Exposes queue occupancy for deterministic backpressure checks.
    var waitingSenderCount: Int {
        get async { await outputGate.waitingCount }
    }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard state == .connected else { throw Failure.closed }
        do {
            try await outputGate.withPermit {
                try await self.sendFrame(data)
            }
        } catch is AsyncExclusiveGate.CapacityExceeded {
            await disconnect()
            throw Failure.outputCapacity
        }
    }

    private func nextFrame() async throws -> Data? {
        try Task.checkCancellation()
        guard state == .connected else { return nil }
        guard !reading else { throw Failure.multipleConsumers }
        reading = true
        defer { reading = false }
        var frame = Data()
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        do {
            while state == .connected {
                try Task.checkCancellation()
                if chunkOffset < chunk.count {
                    let remaining = chunk[chunkOffset...]
                    if let newline = remaining.firstIndex(of: 0x0A) {
                        try append(chunk[chunkOffset..<newline], to: &frame)
                        chunkOffset = newline + 1
                        if !frame.isEmpty { return frame }
                        continue
                    }
                    try append(remaining, to: &frame)
                    chunkOffset = chunk.count
                }
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(input, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    chunk = Data(buffer.prefix(count))
                    chunkOffset = 0
                } else if count == 0 {
                    guard frame.isEmpty else { throw Failure.truncatedFrame }
                    await disconnect()
                    return nil
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    blockedIOObserver?(.input)
                    try await waitForReadiness(.input)
                } else {
                    throw Failure.io
                }
            }
            return nil
        } catch {
            await disconnect()
            throw error
        }
    }

    private func append(_ bytes: Data, to frame: inout Data) throws {
        guard frame.count <= maximumFrameBytes,
              bytes.count <= maximumFrameBytes - frame.count else {
            throw Failure.frameTooLarge
        }
        frame.append(bytes)
    }

    private func sendFrame(_ data: Data) async throws {
        try Task.checkCancellation()
        guard state == .connected else { throw Failure.closed }
        var offset = 0
        var delimiterSent = false
        do {
            while !delimiterSent {
                try Task.checkCancellation()
                guard state == .connected else { throw Failure.closed }
                let count: Int
                if offset < data.count {
                    count = data.withUnsafeBytes { bytes in
                        Darwin.write(output, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                    }
                } else {
                    var newline: UInt8 = 0x0A
                    count = Darwin.write(output, &newline, 1)
                }
                if count > 0 {
                    if offset < data.count { offset += count } else { delimiterSent = true }
                } else if count < 0 && errno == EINTR {
                    continue
                } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    blockedIOObserver?(.output)
                    try await waitForReadiness(.output)
                } else {
                    throw Failure.io
                }
            }
        } catch {
            if offset > 0 || !(error is CancellationError) {
                await disconnect()
            }
            throw error
        }
    }

    private func waitForReadiness(_ direction: IODirection) async throws {
        let readiness = StdioDescriptorReadiness(
            descriptor: direction == .input ? input : output, direction: direction
        )
        switch direction {
        case .input: inputReadiness = readiness
        case .output: outputReadiness = readiness
        }
        defer {
            switch direction {
            case .input: inputReadiness = nil
            case .output: outputReadiness = nil
            }
        }
        do {
            try await readiness.wait()
        } catch {
            // Explicit disconnect ends receive with EOF; task cancellation still
            // escapes so the SDK does not emit a cancelled request's response.
            if state == .closed, !Task.isCancelled { return }
            throw error
        }
    }

    private func makeNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Failure.io
        }
    }

    enum Failure: Error, Equatable {
        case closed, io, multipleConsumers, outputCapacity, frameTooLarge, truncatedFrame
    }
}
