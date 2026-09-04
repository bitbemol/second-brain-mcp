import Foundation
import MCP
import Synchronization
import Testing
@testable import second_brain_mcp

@Suite("MCP shutdown mutation durability")
struct MCPShutdownMutationTests {
    @Test("EOF joins the required Git snapshot after file bytes have persisted")
    func eofDrainsPersistedMutationSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPShutdownMutationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"), withIntermediateDirectories: true
        )
        let dataDirectory = try VaultDataDirectory.prepare(vaultPath: root.path)
        defer {
            try? FileManager.default.removeItem(at: dataDirectory.rootURL)
            try? FileManager.default.removeItem(at: root)
        }
        let access = VaultAccessCoordinator(
            lockURL: dataDirectory.lockDirectoryURL.appendingPathComponent("vault-access.lock")
        )
        let runtime = try await VaultRuntime.bootstrap(
            vaultPath: root.path, readOnly: true, injectedAccess: access
        )
        let target = root.appendingPathComponent("notes/durable.log")
        let expected = Data("durable bytes before shutdown\n".utf8)
        let versioning = try ShutdownSnapshotHold(
            root: root,
            dataDirectory: dataDirectory,
            persistedFile: target
        )
        defer { versioning.release() }
        let sources = ExternalFileSourceValidator(vaultPath: root.path)
        let catalog = FileFormatCatalogFactory.build(
            imageReader: ImageReader(encoder: CoreGraphicsImageEncoder(), limits: .default),
            imageImporter: ImageImporter(
                sourceValidator: sources, encoder: CoreGraphicsImageEncoder(), limits: .default
            ),
            videoImporter: VideoImporter(
                sourceValidator: sources, encoder: AVFoundationVideoEncoder()
            ),
            pdfReader: PDFReader()
        )
        let files = VaultFileService(
            vaultPath: root.path, catalog: catalog,
            store: VaultCRUDStore(vaultPath: root.path),
            mutations: VaultMutationExecutor(versioning: versioning), access: access
        )
        let transports = await InMemoryTransport.createConnectedPair()
        // InMemoryTransport drops messages delivered before its peer connects.
        // Preconnect the server endpoint so Client.connect() cannot lose its
        // initialize request while the server task is only scheduled.
        try await transports.server.connect()
        let returned = Mutex(false)
        let serverTask = Task {
            defer { returned.withLock { $0 = true } }
            try await MCPServerSetup.start(
                config: ServerConfig(vaultPath: root.path, readOnly: false),
                files: files, paths: runtime.paths, search: runtime.search,
                links: runtime.links, listing: runtime.listing,
                capabilities: catalog.capabilities(), transport: transports.server
            )
        }
        let client = Client(name: "ShutdownMutationTest", version: "1.0")
        _ = try await client.connect(transport: transports.client)
        try await transports.client.send(Data(
            #"{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"create_file","arguments":{"format":"log","path":"notes/durable.log","content":"durable bytes before shutdown\n"}}}"#.utf8
        ))

        let entered = await mutationShutdownEventually { versioning.entered }
        // This seam is after real store persistence, not before a mocked mutation.
        let persistedBeforeEOF = versioning.observedBytes
        let snapshotFinishedBeforeEOF = versioning.finished
        await client.disconnect()
        let returnedBeforeSnapshot = await mutationShutdownEventually {
            returned.withLock { $0 }
        }
        versioning.release()
        let snapshotFinished = await mutationShutdownEventually(
            within: .seconds(10)
        ) { versioning.finished }
        try await serverTask.value

        #expect(entered)
        #expect(persistedBeforeEOF == expected)
        #expect(!snapshotFinishedBeforeEOF)
        #expect(!returnedBeforeSnapshot, "EOF returned while persisted bytes lacked the required snapshot")
        #expect(snapshotFinished)
        #expect(versioning.succeeded, "Cancellation must not abandon the post-persistence Git transaction")
        #expect(versioning.calls == 1)
        #expect(try Data(contentsOf: target) == expected)
        let snapshotReference = try latestShutdownSnapshotReference(
            in: root,
            dataDirectory: dataDirectory
        )
        #expect(
            try runShutdownGit(
                ["log", "-1", "--pretty=%s", snapshotReference],
                in: root,
                dataDirectory: dataDirectory
            ) == "Vault snapshot"
        )
    }
}

private func latestShutdownSnapshotReference(
    in root: URL,
    dataDirectory: VaultDataDirectory
) throws -> String {
    try runShutdownGit([
        "for-each-ref",
        "--sort=-refname",
        "--count=1",
        "--format=%(refname)",
        GitRepository.snapshotReferencePrefix,
    ], in: root, dataDirectory: dataDirectory)
}

private func runShutdownGit(
    _ arguments: [String],
    in root: URL,
    dataDirectory: VaultDataDirectory
) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = [
        "--git-dir=\(dataDirectory.snapshotRepositoryURL.path(percentEncoded: false))",
        "--work-tree=\(root.path(percentEncoded: false))",
        "-c", "core.bare=false",
    ] + arguments
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileReadUnknown)
    }
    return String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func mutationShutdownEventually(
    within duration: Duration = .seconds(1),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: duration)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// Holds only the required post-persistence snapshot, then performs real Git work.
private final class ShutdownSnapshotHold: VaultVersioning, Sendable {
    private struct State {
        var calls = 0
        var observedBytes: Data?
        var finished = false
        var succeeded = false
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    private let git: GitRepository
    private let persistedFile: URL

    init(
        root: URL,
        dataDirectory: VaultDataDirectory,
        persistedFile: URL
    ) throws {
        self.git = try GitRepository(vaultURL: root, dataDirectory: dataDirectory)
        self.persistedFile = persistedFile
    }

    var calls: Int { state.withLock { $0.calls } }
    var entered: Bool { calls > 0 }
    var observedBytes: Data? { state.withLock { $0.observedBytes } }
    var finished: Bool { state.withLock { $0.finished } }
    var succeeded: Bool { state.withLock { $0.succeeded } }

    func recordSnapshot() async throws {
        defer { state.withLock { $0.finished = true } }
        let persisted = try Data(contentsOf: persistedFile)
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { value in
                value.calls += 1
                value.observedBytes = persisted
                if value.released { return true }
                value.waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        try await git.recordSnapshot()
        state.withLock { $0.succeeded = true }
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
