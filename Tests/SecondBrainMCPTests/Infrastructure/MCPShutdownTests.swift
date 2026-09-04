import Foundation
import MCP
import Synchronization
import Testing
@testable import second_brain_mcp

@Suite("MCP shutdown ownership")
struct MCPShutdownTests {
    @Test("EOF cancels active tool work and waits for its actual unwind")
    func eofDrainsActiveSearch() async throws {
        try await checkDrain(cancelBeforeEOF: false)
    }

    @Test("EOF still joins a tool already cancelled by the client")
    func eofDrainsPreviouslyCancelledSearch() async throws {
        try await checkDrain(cancelBeforeEOF: true)
    }

    @Test("Closed tool lifetime rejects late SDK dispatch before backend entry")
    func closedLifecycleRejectsLateWork() async throws {
        let lifecycle = MCPToolCallLifecycle()
        await lifecycle.closeAndDrain()
        await lifecycle.closeAndDrain()
        let entered = Mutex(false)
        do {
            _ = try await lifecycle.run {
                entered.withLock { $0 = true }
                return CallTool.Result(content: [])
            }
            Issue.record("Closed tool lifetime accepted new work")
        } catch is CancellationError {
        }
        #expect(!entered.withLock { $0 })
    }

    @Test("A caller already cancelled before registration never enters the backend")
    func cancelledCallerNeverEntersBackend() async throws {
        let lifecycle = MCPToolCallLifecycle()
        let entered = Mutex(false)
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await lifecycle.run {
                    entered.withLock { $0 = true }
                    return CallTool.Result(content: [])
                }
                Issue.record("Cancelled caller started backend work")
            } catch is CancellationError {
            }
        }
        try await caller.value
        await lifecycle.closeAndDrain()
        #expect(!entered.withLock { $0 })
    }

    private func checkDrain(cancelBeforeEOF: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        let dataDirectory = try VaultDataDirectory.prepare(vaultPath: root.path)
        defer {
            try? FileManager.default.removeItem(at: dataDirectory.rootURL)
            try? FileManager.default.removeItem(at: root)
        }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root.path, readOnly: true)
        let transports = await InMemoryTransport.createConnectedPair()
        try await transports.server.connect()
        let hold = ShutdownSearchHold()
        defer { hold.release() }
        let completed = Mutex(false)
        let serverTask = Task {
            defer { completed.withLock { $0 = true } }
            try await MCPServerSetup.start(
                config: ServerConfig(vaultPath: root.path, readOnly: true),
                files: runtime.files, paths: runtime.paths, search: hold,
                links: runtime.links, listing: runtime.listing,
                capabilities: runtime.capabilities, transport: transports.server
            )
        }
        let client = Client(name: "ShutdownOwnershipTest", version: "1.0")
        _ = try await client.connect(transport: transports.client)
        try await transports.client.send(Data(
            #"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"search_vault","arguments":{"location":"notes","query":"held"}}}"#.utf8
        ))
        let entered = await shutdownEventually { hold.entered }
        if cancelBeforeEOF {
            try await transports.client.send(Data(
                #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":42,"reason":"test cancellation"}}"#.utf8
            ))
            let callerCancellationObserved = await shutdownEventually { hold.cancelled }
            #expect(callerCancellationObserved, "Explicit cancellation must reach the owned tool task")
        }
        await client.disconnect()
        let cancellationObserved = await shutdownEventually { hold.cancelled }
        // The bounded observation is a liveness oracle, not a performance threshold.
        let returnedBeforeUnwind = await shutdownEventually { completed.withLock { $0 } }
        hold.release()
        try await serverTask.value
        let unwound = await shutdownEventually { hold.finished }
        #expect(entered)
        #expect(cancellationObserved, "EOF must cancel active backend work")
        #expect(!returnedBeforeUnwind, "MCP setup must not return while a backend still owns resources")
        #expect(unwound)
        #expect(hold.entries == 1)
    }
}

private func shutdownEventually(_ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// Deliberately observes cancellation without releasing its owned resource.
private final class ShutdownSearchHold: VaultSearchService, Sendable {
    let searchableFormats: [FileFormat] = []
    private struct State {
        var entries = 0
        var cancelled = false
        var finished = false
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    var entries: Int { state.withLock { $0.entries } }
    var entered: Bool { entries > 0 }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    var finished: Bool { state.withLock { $0.finished } }

    func search(_ request: VaultSearchRequest) async throws -> VaultSearchResponse {
        defer { state.withLock { $0.finished = true } }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { value in
                    value.entries += 1
                    if value.released { return true }
                    value.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.cancelled = true }
        }
        try Task.checkCancellation()
        return VaultSearchResponse(results: [])
    }

    func release() {
        let waiter = state.withLock { value in
            value.released = true
            let waiter = value.waiter
            value.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}
