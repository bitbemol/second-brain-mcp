import Foundation
import Testing
@testable import SecondBrainMCP

@Suite
struct VaultMutationRecoveryTests {
    @Test
    func failedSnapshotRetriesAfterValidatingPersistedBytes() async throws {
        let context = try makeContext(path: "notes/recover.md", contents: "persisted")
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "recover")
        let output = makeOutput(
            target: context.target,
            identifier: identifier,
            data: context.data
        )
        try context.receipts.savePostPersistenceFailure(
            identifier: identifier,
            fingerprint: fingerprint,
            output: output,
            recoveryEvidence: nil,
            failure: "simulated snapshot failure"
        )
        let versioning = RecoveryVersioningProbe()
        let executor = makeExecutor(
            versioning: versioning,
            dataDirectory: context.dataDirectory,
            receipts: context.receipts
        )
        let preparation = RecoveryCounter()

        let replay = try await executor.executeIdempotent(
            plan: makePlan(context.target, identifier: identifier),
            fingerprint: fingerprint,
            prepare: {
                await preparation.increment()
                return PreparedVaultMutation(
                    requiresSnapshot: false,
                    perform: { .text("must not run") }
                )
            }
        )

        #expect(replay.metadata?.replayed == true)
        #expect(await preparation.value == 0)
        #expect(await versioning.callCount == 1)
    }

    @Test
    func snapshotRecoveryRefusesChangedPersistedBytes() async throws {
        let context = try makeContext(path: "notes/drift.md", contents: "expected")
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "drift")
        try context.receipts.savePostPersistenceFailure(
            identifier: identifier,
            fingerprint: fingerprint,
            output: makeOutput(
                target: context.target,
                identifier: identifier,
                data: context.data
            ),
            recoveryEvidence: nil,
            failure: "simulated snapshot failure"
        )
        try Data("external replacement".utf8).write(
            to: context.target.url,
            options: .atomic
        )
        let versioning = RecoveryVersioningProbe()
        let executor = makeExecutor(
            versioning: versioning,
            dataDirectory: context.dataDirectory,
            receipts: context.receipts
        )

        await #expect(throws: VaultMutationExecutor.ExecutionError.self) {
            _ = try await executor.executeIdempotent(
                plan: makePlan(context.target, identifier: identifier),
                fingerprint: fingerprint,
                prepare: {
                    PreparedVaultMutation(
                        requiresSnapshot: false,
                        perform: { .text("must not run") }
                    )
                }
            )
        }

        #expect(await versioning.callCount == 0)
    }

    @Test
    func orphanedPrePersistenceReceiptRestartsSafely() async throws {
        let root = try makeVault()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let target = try makeTarget("notes/restart.md", root: root)
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "restart")
        try receipts.saveInProgress(
            identifier: identifier,
            fingerprint: fingerprint
        )
        let versioning = RecoveryVersioningProbe()
        let executor = makeExecutor(
            versioning: versioning,
            dataDirectory: dataDirectory,
            receipts: receipts
        )
        let data = Data("restarted".utf8)

        _ = try await executor.executeIdempotent(
            plan: makePlan(target, identifier: identifier),
            fingerprint: fingerprint,
            prepare: {
                PreparedVaultMutation(
                    requiresSnapshot: true,
                    perform: {
                        try data.write(to: target.url, options: .atomic)
                        return self.makeOutput(
                            target: target,
                            identifier: identifier,
                            data: data
                        )
                    }
                )
            }
        )

        #expect(await versioning.callCount == 1)
        #expect(try Data(contentsOf: target.url) == data)
    }

    private struct Context {
        let dataDirectory: VaultDataDirectory
        let receipts: MutationReceiptStore
        let target: WritableFileTarget
        let data: Data
    }

    private func makeContext(path: String, contents: String) throws -> Context {
        let root = try makeVault()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let target = try makeTarget(path, root: root)
        let data = Data(contents.utf8)
        try data.write(to: target.url, options: .atomic)
        return Context(
            dataDirectory: dataDirectory,
            receipts: MutationReceiptStore(dataDirectory: dataDirectory),
            target: target,
            data: data
        )
    }

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory()
            + "VaultMutationRecoveryTests-\(UUID().uuidString)"
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

    private func makeOutput(
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

    private func makeExecutor(
        versioning: any VaultVersioning,
        dataDirectory: VaultDataDirectory,
        receipts: MutationReceiptStore
    ) -> VaultMutationExecutor {
        VaultMutationExecutor(
            versioning: versioning,
            audit: AuditLogger(dataDirectory: dataDirectory),
            receipts: receipts
        )
    }
}

private actor RecoveryVersioningProbe: VaultVersioning {
    private(set) var callCount = 0

    func recordSnapshot() {
        callCount += 1
    }
}

private actor RecoveryCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
