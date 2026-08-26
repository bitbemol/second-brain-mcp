import Foundation
import Logging
import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct `Vault runtime recovery` {
    @Test
    func `Runtime composition is not delayed by pending snapshot recovery`() async throws {
        let root = try makeVault()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }

        _ = try await VaultRuntime.bootstrap(
            vaultPath: root,
            injectedAccess: RejectingMutationAccess()
        )
    }

    @Test
    func `Transport connects before startup recovery finishes`() async throws {
        let root = try makeVault()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        let runtime = try await VaultRuntime.bootstrap(
            vaultPath: root,
            readOnly: true
        )
        let transports = await InMemoryTransport.createConnectedPair()
        let serverStream = await transports.server.receive()
        let probedTransport = RecoveryConnectionProbeTransport(
            base: transports.server,
            stream: serverStream
        )
        let recovery = StartupRecoveryHold()
        let serverTask = Task {
            try await MCPServerSetup.start(
                config: ServerConfig(vaultPath: root, readOnly: true),
                files: runtime.files,
                directories: runtime.directories,
                search: runtime.search,
                capabilities: runtime.capabilities,
                startupRecovery: { await recovery.run() },
                transport: probedTransport
            )
        }

        await recovery.waitUntilEntered()
        let connectedBeforeRecoveryFinished = await probedTransport.isConnected
        await recovery.release()
        await probedTransport.waitUntilConnected()
        try await transports.client.connect()
        await transports.client.disconnect()
        try await serverTask.value

        #expect(connectedBeforeRecoveryFinished)
    }

    @Test
    func `Connected client remains live across successful recovery`() async throws {
        let root = try makeVault()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        try Data("existing".utf8).write(
            to: URL(fileURLWithPath: root)
                .appendingPathComponent("notes/existing.md"),
            options: .atomic
        )
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let transports = await InMemoryTransport.createConnectedPair()
        let recovery = StartupRecoveryHold()
        let completion = ServerCompletionProbe()
        let serverTask = Task {
            do {
                try await MCPServerSetup.start(
                    config: ServerConfig(vaultPath: root, readOnly: false),
                    files: runtime.files,
                    directories: runtime.directories,
                    search: runtime.search,
                    capabilities: runtime.capabilities,
                    startupRecovery: { await recovery.run() },
                    transport: transports.server
                )
                await completion.markCompleted()
            } catch {
                await completion.markCompleted()
                throw error
            }
        }

        await recovery.waitUntilEntered()
        let client = Client(name: "RecoveryLifecycleTest", version: "1.0")
        _ = try await client.connect(transport: transports.client)
        let beforeRecovery: (content: [Tool.Content], isError: Bool?) =
            try await client.callTool(
                name: "read_file",
                arguments: [
                    "format": "markdown",
                    "path": "notes/existing.md",
                ]
            )
        #expect(beforeRecovery.isError != true)

        await recovery.release()
        await recovery.waitUntilFinished()

        let afterRecovery: (content: [Tool.Content], isError: Bool?) =
            try await client.callTool(
                name: "read_file",
                arguments: [
                    "format": "markdown",
                    "path": "notes/existing.md",
                ]
            )
        #expect(afterRecovery.isError != true)
        let mutation: (content: [Tool.Content], isError: Bool?) =
            try await client.callTool(
                name: "create_file",
                arguments: [
                    "format": "markdown",
                    "path": "notes/after-recovery.md",
                    "content": "created after recovery",
                ]
            )
        #expect(mutation.isError != true)
        #expect(await completion.isCompleted == false)

        await client.disconnect()
        try await serverTask.value
    }

    @Test
    func `Startup recovery failure does not disconnect an initialized client`() async throws {
        let root = try makeVault()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let transports = await InMemoryTransport.createConnectedPair()
        let recovery = FailingStartupRecoveryHold()
        let completion = ServerCompletionProbe()
        let serverTask = Task {
            do {
                try await MCPServerSetup.start(
                    config: ServerConfig(vaultPath: root, readOnly: false),
                    files: runtime.files,
                    directories: runtime.directories,
                    search: runtime.search,
                    capabilities: runtime.capabilities,
                    startupRecovery: { try await recovery.run() },
                    transport: transports.server
                )
                await completion.markCompleted()
            } catch {
                await completion.markCompleted()
                throw error
            }
        }

        await recovery.waitUntilEntered()
        let client = Client(name: "RecoveryFailureTest", version: "1.0")
        _ = try await client.connect(transport: transports.client)
        let toolsBeforeFailure = try await client.listTools().tools
        #expect(!toolsBeforeFailure.isEmpty)

        await recovery.release()
        await recovery.waitUntilFinished()
        let serverExited = await completion.completes(within: .milliseconds(500))
        if serverExited {
            await client.disconnect()
            _ = await serverTask.result
        }
        try #require(
            serverExited == false,
            "Recovery failure stopped the connected MCP server"
        )

        var mutationReportedRecoveryFailure = false
        do {
            let _: (content: [Tool.Content], isError: Bool?) =
                try await client.callTool(
                    name: "create_file",
                    arguments: [
                        "format": "markdown",
                        "path": "notes/blocked.md",
                        "content": "must not persist",
                    ]
                )
        } catch {
            mutationReportedRecoveryFailure = true
        }
        #expect(mutationReportedRecoveryFailure)
        #expect(try await client.listTools().tools.count == toolsBeforeFailure.count)

        await client.disconnect()
        try await serverTask.value
    }

    @Test
    func `Writable startup snapshots pending note changes`() async throws {
        let root = try makeVault()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        try Data("pending".utf8).write(
            to: URL(fileURLWithPath: root)
                .appendingPathComponent("notes/pending.md"),
            options: .atomic
        )

        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        try await runtime.recoverPendingChanges()

        #expect(
            try runGit(["status", "--porcelain", "--", "notes"], at: root)
                .isEmpty
        )
        #expect(
            try runGit(["log", "-1", "--pretty=%s"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "Vault snapshot"
        )
    }

    @Test
    func `Startup leaves reference content outside history`() async throws {
        let root = try makeVault()
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        try Data("large immutable reference".utf8).write(
            to: URL(fileURLWithPath: root)
                .appendingPathComponent("references/book.txt"),
            options: .atomic
        )
        try Data("tracked note".utf8).write(
            to: URL(fileURLWithPath: root)
                .appendingPathComponent("notes/note.md"),
            options: .atomic
        )
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }

        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        try await runtime.recoverPendingChanges()

        #expect(
            try runGit(
                ["ls-tree", "-r", "--name-only", "HEAD", "--", "references"],
                at: root
            ).isEmpty
        )
    }

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory()
            + "VaultRuntimeRecoveryTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        return root
    }

    private func productionDataDirectory(for root: String) throws -> VaultDataDirectory {
        try VaultDataDirectory.prepare(
            vaultPath: root
        )
    }

    private func cleanup(root: String, dataDirectory: VaultDataDirectory) {
        try? FileManager.default.removeItem(at: dataDirectory.rootURL)
        try? FileManager.default.removeItem(atPath: root)
    }

    private func runGit(_ arguments: [String], at root: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RuntimeRecoveryGitInspectionError.commandFailed
        }
        return String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    private enum RuntimeRecoveryGitInspectionError: Error {
        case commandFailed
    }
}

private struct RejectingMutationAccess: VaultAccessCoordinating {
    private struct RecoveryStarted: Error {}

    func withRead<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await operation()
    }

    func withMutation<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        throw RecoveryStarted()
    }
}

private actor StartupRecoveryHold {
    private var entered = false
    private var finished = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func run() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
        finished = true
        finishWaiters.forEach { $0.resume() }
        finishWaiters.removeAll()
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct InjectedStartupRecoveryFailure: Error {}

private actor FailingStartupRecoveryHold {
    private var entered = false
    private var finished = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func run() async throws {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
        finished = true
        finishWaiters.forEach { $0.resume() }
        finishWaiters.removeAll()
        throw InjectedStartupRecoveryFailure()
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor ServerCompletionProbe {
    private var completed = false

    var isCompleted: Bool { completed }

    func markCompleted() {
        completed = true
    }

    func completes(within duration: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while !completed && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return completed
    }
}

private actor RecoveryConnectionProbeTransport: Transport {
    nonisolated let logger: Logger
    private let base: InMemoryTransport
    private let stream: AsyncThrowingStream<Data, Error>
    private var connected = false
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        base: InMemoryTransport,
        stream: AsyncThrowingStream<Data, Error>
    ) {
        self.base = base
        self.stream = stream
        self.logger = base.logger
    }

    var isConnected: Bool { connected }

    func waitUntilConnected() async {
        guard !connected else { return }
        await withCheckedContinuation { connectionWaiters.append($0) }
    }

    func connect() async throws {
        try await base.connect()
        connected = true
        connectionWaiters.forEach { $0.resume() }
        connectionWaiters.removeAll()
    }

    func disconnect() async {
        await base.disconnect()
    }

    func send(_ data: Data) async throws {
        try await base.send(data)
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }
}
