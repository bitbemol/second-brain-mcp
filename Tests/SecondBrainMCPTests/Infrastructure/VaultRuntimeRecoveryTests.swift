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
    func `Startup recovery holds shared vault access so reads remain available`() async throws {
        let root = try makeVault()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        let runtime = try await VaultRuntime.bootstrap(
            vaultPath: root,
            injectedAccess: RejectingMutationAccess()
        )

        try await runtime.recoverPendingChanges()
    }

    @Test
    func `Initialization reports first public v2 version`() async throws {
        let root = try makeVault()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        let runtime = try await VaultRuntime.bootstrap(
            vaultPath: root,
            readOnly: true
        )
        let transports = await InMemoryTransport.createConnectedPair()
        try await transports.server.connect()
        let serverTask = Task {
            try await MCPServerSetup.start(
                config: ServerConfig(vaultPath: root, readOnly: true),
                files: runtime.files,
                paths: runtime.paths,
                search: runtime.search,
                links: runtime.links,
                listing: runtime.listing,
                capabilities: runtime.capabilities,
                transport: transports.server
            )
        }
        let client = Client(name: "VersionContractTest", version: "1.0")

        let initialization = try await client.connect(transport: transports.client)

        #expect(initialization.serverInfo.name == "SecondBrainMCP")
        #expect(initialization.serverInfo.version == "2.0.0")
        let instructions = try #require(initialization.instructions)
        #expect(instructions.contains("list_files for inventory"))
        #expect(instructions.contains("search_vault for content"))
        #expect(instructions.contains("query_links for local wiki/Markdown relationships"))
        #expect(instructions.contains("read_file with view=metadata"))
        #expect(instructions.contains("Keep cursor criteria unchanged"))
        #expect(instructions.contains("limit may change"))
        #expect(instructions.contains("coverage.complete=false cannot establish absence"))
        #expect(instructions.contains("restart stale"))
        #expect(instructions.contains("text_window.next_byte_offset"))
        #expect(instructions.contains("expected_revision"))
        let toolNames = Set(try await client.listTools().tools.map(\.name))
        #expect(toolNames == [
            "list_files", "query_links", "read_file", "search_vault",
        ])

        await client.disconnect()
        try await serverTask.value
    }

    @Test
    func `Writable initialization registers exact composable v2 tool surface`() async throws {
        let root = try makeVault()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let transports = await InMemoryTransport.createConnectedPair()
        try await transports.server.connect()
        let serverTask = Task {
            try await MCPServerSetup.start(
                config: ServerConfig(vaultPath: root, readOnly: false),
                files: runtime.files,
                paths: runtime.paths,
                search: runtime.search,
                links: runtime.links,
                listing: runtime.listing,
                capabilities: runtime.capabilities,
                transport: transports.server
            )
        }
        let client = Client(name: "WritableSurfaceTest", version: "1.0")

        _ = try await client.connect(transport: transports.client)
        let toolNames = Set(try await client.listTools().tools.map(\.name))
        #expect(toolNames == [
            "create_file", "delete_file", "list_files", "move_path",
            "query_links", "read_file", "search_vault", "update_file",
        ])

        await client.disconnect()
        try await serverTask.value
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
                paths: runtime.paths,
                search: runtime.search,
                links: runtime.links,
                listing: runtime.listing,
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
                    paths: runtime.paths,
                    search: runtime.search,
                    links: runtime.links,
                    listing: runtime.listing,
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
                    paths: runtime.paths,
                    search: runtime.search,
                    links: runtime.links,
                    listing: runtime.listing,
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
            let response: (content: [Tool.Content], isError: Bool?) =
                try await client.callTool(
                    name: "create_file",
                    arguments: [
                        "format": "markdown",
                        "path": "notes/blocked.md",
                        "content": "must not persist",
                    ]
                )
            mutationReportedRecoveryFailure = response.isError == true
        } catch {
            Issue.record("Recovery failure escaped the tool result: \(error)")
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
        let snapshotReference = try latestSnapshotReference(at: root)

        #expect(
            try runGit(
                ["ls-tree", "-r", "--name-only", snapshotReference, "--", "notes"],
                at: root
            ).trimmingCharacters(in: .whitespacesAndNewlines) == "notes/pending.md"
        )
        #expect(
            try runGit(["log", "-1", "--pretty=%s", snapshotReference], at: root)
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
        let snapshotReference = try latestSnapshotReference(at: root)

        #expect(
            try runGit(
                [
                    "ls-tree", "-r", "--name-only", snapshotReference,
                    "--", "references",
                ],
                at: root
            ).isEmpty
        )
    }

    @Test
    func recoveryFailureDoesNotLeakPrivateDetails() async throws {
        let root = try makeVault()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root, readOnly: true)
        let transports = await InMemoryTransport.createConnectedPair()
        try await transports.server.connect()
        let marker = "PRIVATE_RECOVERY_MARKER"
        let serverTask = Task {
            try await MCPServerSetup.start(
                config: ServerConfig(vaultPath: root, readOnly: false),
                files: runtime.files, paths: runtime.paths, search: runtime.search,
                links: runtime.links, listing: runtime.listing,
                capabilities: runtime.capabilities,
                startupRecovery: {
                    throw NSError(
                        domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                        userInfo: [
                            NSLocalizedDescriptionKey: "/private/recovery/" + marker +
                                String(repeating: "x", count: 1_024),
                        ]
                    )
                },
                transport: transports.server
            )
        }
        let client = Client(name: "RecoveryFailureBoundary", version: "1.0")
        _ = try await client.connect(transport: transports.client)
        var returnedToolFailure = false
        let message: String
        do {
            let response = try await client.callTool(name: "create_file", arguments: [
                "format": .string("markdown"), "path": .string("notes/blocked.md"),
                "content": .string("must not persist"),
            ])
            returnedToolFailure = response.isError == true
            message = response.content.compactMap { content -> String? in
                if case .text(let text, _, _) = content { return text }
                return nil
            }.joined()
        } catch {
            message = String(describing: error)
        }
        #expect(returnedToolFailure)
        #expect(message.utf8.count <= 512)
        #expect(!message.contains(marker))
        #expect(!message.contains("/private/recovery/"))
        #expect(try await client.listTools().tools.count == 8)
        #expect(!FileManager.default.fileExists(atPath: root + "/notes/blocked.md"))
        await client.disconnect()
        try await serverTask.value
    }

    @Test
    func `Repeated mutation failures identify fresh private recovery attempts`() async throws {
        let root = try makeVault()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root, readOnly: true)
        let transports = await InMemoryTransport.createConnectedPair()
        try await transports.server.connect()
        let recovery = CountingPrivateSnapshotFailure()
        let serverTask = Task {
            try await MCPServerSetup.start(
                config: ServerConfig(vaultPath: root, readOnly: false),
                files: runtime.files, paths: runtime.paths, search: runtime.search,
                links: runtime.links, listing: runtime.listing,
                capabilities: runtime.capabilities,
                startupRecovery: { try await recovery.run() },
                transport: transports.server
            )
        }
        let client = Client(name: "RecoveryAttemptDiagnostics", version: "1.0")
        _ = try await client.connect(transport: transports.client)
        await recovery.waitForAttempts(1)

        let secondAttemptMessage = try await recoveryFailureMessage(from: client)
        let thirdAttemptMessage = try await recoveryFailureMessage(from: client)

        #expect(secondAttemptMessage.contains("Recovery attempt 2 failed"))
        #expect(thirdAttemptMessage.contains("Recovery attempt 3 failed"))
        #expect(secondAttemptMessage.contains("private snapshot store"))
        #expect(thirdAttemptMessage.contains("private snapshot store"))
        for message in [secondAttemptMessage, thirdAttemptMessage] {
            #expect(!message.contains(CountingPrivateSnapshotFailure.privateArgument))
            #expect(!message.contains(CountingPrivateSnapshotFailure.privateStatus))
            #expect(!message.contains(CountingPrivateSnapshotFailure.privateMessage))
            #expect(message.utf8.count <= 512)
        }

        #expect(await recovery.attempts == 3)
        await client.disconnect()
        try await serverTask.value
    }

    @Test
    func `Restored private pack resumes mutation without restarting server`() async throws {
        let root = try makeVault()
        let dataDirectory = try productionDataDirectory(for: root)
        defer { cleanup(root: root, dataDirectory: dataDirectory) }
        let existing = URL(fileURLWithPath: root)
            .appendingPathComponent("notes/existing.md")
        try Data("baseline".utf8).write(to: existing, options: .atomic)
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        try await runtime.recoverPendingChanges()
        _ = try runGit(["repack", "-ad"], at: root)
        let packDirectory = dataDirectory.snapshotRepositoryURL
            .appendingPathComponent("objects/pack", isDirectory: true)
        let packFiles = try FileManager.default.contentsOfDirectory(
            at: packDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "pack" }
        let pack = try #require(packFiles.count == 1 ? packFiles[0] : nil)
        let savedPack = try Data(contentsOf: pack)
        defer { try? savedPack.write(to: pack, options: .atomic) }
        try Data("truncated".utf8).write(to: pack, options: .atomic)

        let attempts = RecoveryAttemptCounter()
        let transports = await InMemoryTransport.createConnectedPair()
        try await transports.server.connect()
        let serverTask = Task {
            try await MCPServerSetup.start(
                config: ServerConfig(vaultPath: root, readOnly: false),
                files: runtime.files, paths: runtime.paths, search: runtime.search,
                links: runtime.links, listing: runtime.listing,
                capabilities: runtime.capabilities,
                startupRecovery: {
                    try await attempts.run { try await runtime.recoverPendingChanges() }
                },
                transport: transports.server
            )
        }
        let client = Client(name: "PrivatePackRepair", version: "1.0")
        _ = try await client.connect(transport: transports.client)

        let read = try await client.callTool(name: "read_file", arguments: [
            "format": .string("markdown"), "path": .string("notes/existing.md"),
        ])
        #expect(read.isError != true)
        let blocked = try await client.callTool(name: "create_file", arguments: [
            "format": .string("markdown"), "path": .string("notes/recovered.md"),
            "content": .string("same session"),
        ])
        #expect(blocked.isError == true)
        #expect(!FileManager.default.fileExists(atPath: root + "/notes/recovered.md"))
        let failedAttempts = await attempts.count

        try savedPack.write(to: pack, options: .atomic)
        let recovered = try await client.callTool(name: "create_file", arguments: [
            "format": .string("markdown"), "path": .string("notes/recovered.md"),
            "content": .string("same session"),
        ])

        #expect(recovered.isError != true)
        #expect(await attempts.count == failedAttempts + 1)
        let recoveredURL = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("notes/recovered.md")
        try #require(FileManager.default.fileExists(atPath: recoveredURL.path))
        let recoveredBytes = try Data(contentsOf: recoveredURL)
        #expect(String(decoding: recoveredBytes, as: UTF8.self).hasSuffix("same session"))
        let newest = try latestSnapshotReference(at: root)
        let snapshotted = try runGit(["show", "\(newest):notes/recovered.md"], at: root)
        #expect(
            snapshotted == String(decoding: recoveredBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )

        await client.disconnect()
        try await serverTask.value
    }

    private func recoveryFailureMessage(from client: Client) async throws -> String {
        let response = try await client.callTool(name: "create_file", arguments: [
            "format": .string("markdown"), "path": .string("notes/blocked.md"),
            "content": .string("must not persist"),
        ])
        #expect(response.isError == true)
        return response.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined()
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
        let dataDirectory = try productionDataDirectory(for: root)
        process.arguments = [
            "--git-dir=\(dataDirectory.snapshotRepositoryURL.path)",
            "--work-tree=\(root)",
            "-c", "core.bare=false",
        ] + arguments
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

    private func latestSnapshotReference(at root: String) throws -> String {
        try runGit([
            "for-each-ref",
            "--sort=-refname",
            "--count=1",
            "--format=%(refname)",
            GitRepository.snapshotReferencePrefix,
        ], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
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

private actor RecoveryAttemptCounter {
    private(set) var count = 0

    func run(_ operation: @Sendable () async throws -> Void) async throws {
        count += 1
        try await operation()
    }
}

private actor CountingPrivateSnapshotFailure {
    static let privateArgument = "PRIVATE_GIT_ARGUMENT"
    static let privateStatus = "PRIVATE_GIT_STATUS"
    static let privateMessage = "PRIVATE_GIT_STDERR"

    private(set) var attempts = 0
    private var attemptWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func run() throws {
        attempts += 1
        let ready = attemptWaiters.filter { attempts >= $0.0 }
        attemptWaiters.removeAll { attempts >= $0.0 }
        ready.forEach { $0.1.resume() }
        throw VaultVersioningError.gitCommandFailed(
            arguments: [Self.privateArgument],
            status: Self.privateStatus,
            message: Self.privateMessage
        )
    }

    func waitForAttempts(_ count: Int) async {
        guard attempts < count else { return }
        await withCheckedContinuation { continuation in
            attemptWaiters.append((count, continuation))
        }
    }
}

private actor FailingStartupRecoveryHold {
    private var entered = false
    private var finished = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func run() async throws {
        if released {
            throw InjectedStartupRecoveryFailure()
        }
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
        released = true
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
