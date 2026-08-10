import Foundation
import Testing
@testable import SecondBrainMCP

@Suite
struct VaultMutationExecutorTests {
    @Test
    func successfulPersistenceRequestsOneSnapshot() async throws {
        let root = try makeVault()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let versioning = VersioningProbe()
        let executor = VaultMutationExecutor(
            versioning: versioning,
            audit: AuditLogger(dataDirectory: dataDirectory),
            receipts: MutationReceiptStore(dataDirectory: dataDirectory)
        )
        let store = VaultCRUDStore(vaultPath: root)
        let target = try makeTarget("notes/snapshot.md", root: root)
        let identifier = MutationID()
        let data = Data("snapshot".utf8)

        let result = try await executor.executeIdempotent(
            plan: makePlan(target, identifier: identifier),
            fingerprint: MutationRequestFingerprint(rawValue: "snapshot"),
            prepare: {
                PreparedVaultMutation(
                    requiresSnapshot: true,
                    perform: {
                        try await store.create(target: target, data: data)
                        return self.output(
                            target: target,
                            identifier: identifier,
                            data: data
                        )
                    }
                )
            }
        )

        #expect(result.metadata?.mutationID == identifier)
        #expect(await versioning.callCount == 1)
        #expect(try Data(contentsOf: target.url) == data)
    }

    @Test
    func identicalRetryReplaysWithoutPreparingOrSnapshottingAgain() async throws {
        let root = try makeVault()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let versioning = VersioningProbe()
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let executor = VaultMutationExecutor(
            versioning: versioning,
            audit: AuditLogger(dataDirectory: dataDirectory),
            receipts: receipts
        )
        let target = try makeTarget("notes/replay.md", root: root)
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "replay")
        let data = Data("replay".utf8)
        let preparation = Counter()

        func execute() async throws -> FileOperationOutput {
            try await executor.executeIdempotent(
                plan: makePlan(target, identifier: identifier),
                fingerprint: fingerprint,
                prepare: {
                    await preparation.increment()
                    return PreparedVaultMutation(
                        requiresSnapshot: true,
                        perform: {
                            try data.write(to: target.url, options: .atomic)
                            return self.output(
                                target: target,
                                identifier: identifier,
                                data: data
                            )
                        }
                    )
                }
            )
        }

        _ = try await execute()
        let replay = try await execute()

        #expect(replay.metadata?.replayed == true)
        #expect(await preparation.value == 1)
        #expect(await versioning.callCount == 1)
    }

    @Test
    func snapshotFailureRetriesWithoutPersistingTwice() async throws {
        let root = try makeVault()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let versioning = VersioningProbe(failuresBeforeSuccess: 1)
        let executor = VaultMutationExecutor(
            versioning: versioning,
            audit: AuditLogger(dataDirectory: dataDirectory),
            receipts: MutationReceiptStore(dataDirectory: dataDirectory)
        )
        let target = try makeTarget("notes/recover.md", root: root)
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "recover")
        let data = Data("persisted once".utf8)
        let persistence = Counter()

        func execute() async throws -> FileOperationOutput {
            try await executor.executeIdempotent(
                plan: makePlan(target, identifier: identifier),
                fingerprint: fingerprint,
                prepare: {
                    PreparedVaultMutation(
                        requiresSnapshot: true,
                        perform: {
                            await persistence.increment()
                            try data.write(to: target.url, options: .atomic)
                            return self.output(
                                target: target,
                                identifier: identifier,
                                data: data
                            )
                        }
                    )
                }
            )
        }

        await #expect(throws: VaultMutationExecutor.ExecutionError.self) {
            _ = try await execute()
        }
        let replay = try await execute()

        #expect(replay.metadata?.replayed == true)
        #expect(await persistence.value == 1)
        #expect(await versioning.callCount == 2)
    }

    @Test
    func persistenceStartedReceiptFailsClosedForExactRetry() async throws {
        let root = try makeVault()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "uncertain")
        try receipts.saveInProgress(
            identifier: identifier,
            fingerprint: fingerprint
        )
        try receipts.markPersistenceStarted(
            identifier: identifier,
            fingerprint: fingerprint
        )
        let executor = VaultMutationExecutor(
            versioning: VersioningProbe(),
            audit: AuditLogger(dataDirectory: dataDirectory),
            receipts: receipts
        )
        let target = try makeTarget("notes/uncertain.md", root: root)
        let preparation = Counter()

        await #expect(throws: VaultMutationExecutor.ExecutionError.self) {
            _ = try await executor.executeIdempotent(
                plan: makePlan(target, identifier: identifier),
                fingerprint: fingerprint,
                prepare: {
                    await preparation.increment()
                    return PreparedVaultMutation(
                        requiresSnapshot: false,
                        perform: { .text("must not run") }
                    )
                }
            )
        }

        #expect(await preparation.value == 0)
    }

    @Test
    func independentExecutorsDoNotOwnGitSerialization() async throws {
        let root = try makeVault()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let versioningLockURL = dataDirectory.lockDirectoryURL
            .appendingPathComponent("vault-versioning.lock")
        let firstExecutor = VaultMutationExecutor(
            versioning: try GitRepository(
                repositoryURL: URL(fileURLWithPath: root, isDirectory: true),
                lockURL: versioningLockURL
            ),
            audit: AuditLogger(dataDirectory: dataDirectory),
            receipts: MutationReceiptStore(dataDirectory: dataDirectory)
        )
        let secondExecutor = VaultMutationExecutor(
            versioning: try GitRepository(
                repositoryURL: URL(fileURLWithPath: root, isDirectory: true),
                lockURL: versioningLockURL
            ),
            audit: AuditLogger(dataDirectory: dataDirectory),
            receipts: MutationReceiptStore(dataDirectory: dataDirectory)
        )
        let firstStore = VaultCRUDStore(vaultPath: root)
        let secondStore = VaultCRUDStore(vaultPath: root)
        let firstTarget = try makeTarget("notes/first-agent.md", root: root)
        let secondTarget = try makeTarget("notes/second-agent.md", root: root)
        let concurrency = ConcurrencyProbe()
        let firstIdentifier = MutationID()
        let secondIdentifier = MutationID()
        let firstData = Data("first".utf8)
        let secondData = Data("second".utf8)

        async let first = firstExecutor.executeIdempotent(
            plan: makePlan(firstTarget, identifier: firstIdentifier),
            fingerprint: MutationRequestFingerprint(rawValue: "first-agent"),
            prepare: {
                PreparedVaultMutation(
                    requiresSnapshot: true,
                    perform: {
                        await concurrency.enter()
                        try await Task.sleep(for: .milliseconds(30))
                        try await firstStore.create(
                            target: firstTarget,
                            data: firstData
                        )
                        await concurrency.leave()
                        return self.output(
                            target: firstTarget,
                            identifier: firstIdentifier,
                            data: firstData
                        )
                    }
                )
            }
        )
        async let second = secondExecutor.executeIdempotent(
            plan: makePlan(secondTarget, identifier: secondIdentifier),
            fingerprint: MutationRequestFingerprint(rawValue: "second-agent"),
            prepare: {
                PreparedVaultMutation(
                    requiresSnapshot: true,
                    perform: {
                        await concurrency.enter()
                        try await Task.sleep(for: .milliseconds(30))
                        try await secondStore.create(
                            target: secondTarget,
                            data: secondData
                        )
                        await concurrency.leave()
                        return self.output(
                            target: secondTarget,
                            identifier: secondIdentifier,
                            data: secondData
                        )
                    }
                )
            }
        )
        _ = try await (first, second)

        #expect(await concurrency.maximum == 2)
        #expect(try runGit(["status", "--porcelain", "--", "notes"], at: root).isEmpty)
    }

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory()
            + "VaultMutationExecutorTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeTarget(
        _ path: String,
        root: String
    ) throws -> WritableFileTarget {
        try WritableFileTarget.resolve(
            path: path,
            format: .markdown,
            vaultPath: root
        )
    }

    private func makePlan(
        _ target: WritableFileTarget,
        identifier: MutationID
    ) -> VaultMutationPlan {
        VaultMutationPlan(
            kind: .create,
            target: target,
            handler: .markdown,
            mutationID: identifier
        )
    }

    private func output(
        target: WritableFileTarget,
        identifier: MutationID,
        data: Data
    ) -> FileOperationOutput {
        FileOperationOutput.text("Saved").withMetadata(FileOperationMetadata(
            path: target.relativePath,
            area: .notes,
            revision: FileSnapshot(data: data, modifiedDate: nil).revision,
            mutationID: identifier,
            replayed: false
        ))
    }

    private func runGit(_ arguments: [String], at root: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitInspectionError.commandFailed
        }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    private enum GitInspectionError: Error {
        case commandFailed
    }
}

private actor VersioningProbe: VaultVersioning {
    enum ProbeError: Error {
        case simulatedFailure
    }

    private(set) var callCount = 0
    private var failuresBeforeSuccess: Int

    init(failuresBeforeSuccess: Int = 0) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func recordSnapshot() async throws {
        callCount += 1
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw ProbeError.simulatedFailure
        }
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor ConcurrencyProbe {
    private var active = 0
    private(set) var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() {
        active -= 1
    }
}
