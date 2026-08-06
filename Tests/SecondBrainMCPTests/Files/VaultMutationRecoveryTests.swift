import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Vault mutation recovery")
struct VaultMutationRecoveryTests {
    @Test("An orphan pre-persistence intent restarts safely")
    func orphanIntentRestarts() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "orphan-intent")
        try receipts.saveInProgress(
            identifier: identifier,
            fingerprint: fingerprint
        )
        let target = try WritableFileTarget.resolve(
            path: "notes/orphan.md",
            format: .markdown,
            vaultPath: root
        )
        let store = VaultCRUDStore(vaultPath: root)
        let data = Data("safe restart".utf8)
        let probe = RecoveryAttemptProbe()
        let output = makeOutput(
            target: target,
            identifier: identifier,
            data: data
        )
        let executor = makeExecutor(
            git: git,
            dataDirectory: dataDirectory,
            receipts: receipts
        )

        let result = try await executor.executeIdempotent(
            plan: VaultMutationPlan(
                kind: .create,
                target: target,
                handler: .markdown,
                mutationID: identifier
            ),
            fingerprint: fingerprint,
            prepare: {
                await probe.recordPreparation()
                return PreparedVaultMutation(
                    requiresCommit: true,
                    perform: {
                        await probe.recordPersistence()
                        try await store.create(target: target, data: data)
                        return output
                    }
                )
            }
        )

        #expect(result.metadata?.replayed == false)
        #expect(await probe.preparationCount == 1)
        #expect(await probe.persistenceCount == 1)
        #expect(try receipts.activeTransaction() == nil)
        #expect(try String(contentsOf: target.url, encoding: .utf8) == "safe restart")
    }

    @Test("A commit completed before a crash is finalized without another commit")
    func committedRecoveryFinalizesWithoutRecommit() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "commit-then-crash")
        let target = try WritableFileTarget.resolve(
            path: "notes/already-committed.md",
            format: .markdown,
            vaultPath: root
        )
        let data = Data("already persisted".utf8)
        try data.write(to: target.url, options: .atomic)
        let output = makeOutput(
            target: target,
            identifier: identifier,
            data: data
        )
        try await git.commitChange(
            files: [target.relativePath],
            message: "[SecondBrainMCP] Created markdown: \(target.relativePath) [mutation \(identifier.rawValue)]"
        )
        try receipts.saveActiveTransaction(
            identifier: identifier,
            fingerprint: fingerprint
        )
        try receipts.savePostPersistenceFailure(
            identifier: identifier,
            fingerprint: fingerprint,
            output: output,
            failure: "simulated crash before receipt finalization"
        )
        try installFailingCommitHook(at: root)
        let probe = RecoveryAttemptProbe()
        let executor = makeExecutor(
            git: git,
            dataDirectory: dataDirectory,
            receipts: receipts
        )

        let recovered = try await executor.executeIdempotent(
            plan: VaultMutationPlan(
                kind: .create,
                target: target,
                handler: .markdown,
                mutationID: identifier
            ),
            fingerprint: fingerprint,
            prepare: {
                await probe.recordPreparation()
                return PreparedVaultMutation(
                    requiresCommit: false,
                    perform: { .text("must not run") }
                )
            }
        )

        #expect(recovered.metadata?.replayed == true)
        #expect(await probe.preparationCount == 0)
        #expect(try receipts.activeTransaction() == nil)
        #expect(
            try runGit(
                ["rev-list", "--count", "HEAD", "--", target.relativePath],
                at: root
            ).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        )
    }

    @Test("Commit-only recovery refuses changed persisted bytes")
    func recoveryRejectsTargetDrift() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "target-drift")
        let target = try WritableFileTarget.resolve(
            path: "notes/drift.md",
            format: .markdown,
            vaultPath: root
        )
        let original = Data("original persisted bytes".utf8)
        try original.write(to: target.url, options: .atomic)
        let output = makeOutput(
            target: target,
            identifier: identifier,
            data: original
        )
        try receipts.saveActiveTransaction(
            identifier: identifier,
            fingerprint: fingerprint
        )
        try receipts.savePostPersistenceFailure(
            identifier: identifier,
            fingerprint: fingerprint,
            output: output,
            failure: "simulated git failure"
        )
        try Data("external replacement".utf8).write(to: target.url, options: .atomic)
        let probe = RecoveryAttemptProbe()
        let executor = makeExecutor(
            git: git,
            dataDirectory: dataDirectory,
            receipts: receipts
        )

        do {
            _ = try await executor.executeIdempotent(
                plan: VaultMutationPlan(
                    kind: .create,
                    target: target,
                    handler: .markdown,
                    mutationID: identifier
                ),
                fingerprint: fingerprint,
                prepare: {
                    await probe.recordPreparation()
                    return PreparedVaultMutation(
                        requiresCommit: false,
                        perform: { .text("must not run") }
                    )
                }
            )
            Issue.record("Expected recovery to reject changed persisted bytes")
        } catch VaultMutationExecutor.ExecutionError.recoveryStateChanged(
            let path,
            let receivedIdentifier
        ) {
            #expect(path == target.relativePath)
            #expect(receivedIdentifier == identifier)
        } catch {
            Issue.record("Unexpected recovery error: \(error)")
        }

        #expect(await probe.preparationCount == 0)
        #expect(try receipts.activeTransaction()?.identifier == identifier)
        #expect(
            try runGit(
                ["rev-list", "--count", "HEAD", "--", target.relativePath],
                at: root
            ).trimmingCharacters(in: .whitespacesAndNewlines) == "0"
        )
    }

    @Test("Delete recovery refuses changed trash bytes")
    func deleteRecoveryRejectsTrashDrift() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "delete-trash-drift")
        let target = try WritableFileTarget.resolve(
            path: "notes/delete-drift.md",
            format: .markdown,
            vaultPath: root
        )
        let original = Data("original deleted bytes".utf8)
        try original.write(to: target.url, options: .atomic)
        let trashPath = ".trash/deleted-delete-drift.md"
        let trashURL = URL(fileURLWithPath: root).appendingPathComponent(trashPath)
        try FileManager.default.createDirectory(
            at: trashURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: target.url, to: trashURL)
        let output = FileOperationOutput.text(
            "Deleted \(target.relativePath) → \(trashPath)"
        ).withMetadata(FileOperationMetadata(
            path: target.relativePath,
            area: .notes,
            revision: nil,
            mutationID: identifier,
            replayed: false,
        ))
        try receipts.saveActiveTransaction(
            identifier: identifier,
            fingerprint: fingerprint
        )
        try receipts.savePostPersistenceFailure(
            identifier: identifier,
            fingerprint: fingerprint,
            output: output,
            recoveryEvidence: .softDeleted(
                path: trashPath,
                revision: FileSnapshot(data: original, modifiedDate: nil).revision
            ),
            failure: "simulated git failure"
        )
        try Data("external trash replacement".utf8).write(
            to: trashURL,
            options: .atomic
        )
        let probe = RecoveryAttemptProbe()
        let executor = makeExecutor(
            git: git,
            dataDirectory: dataDirectory,
            receipts: receipts
        )

        do {
            _ = try await executor.executeIdempotent(
                plan: VaultMutationPlan(
                    kind: .delete,
                    target: target,
                    handler: .markdown,
                    mutationID: identifier
                ),
                fingerprint: fingerprint,
                prepare: {
                    await probe.recordPreparation()
                    return PreparedVaultMutation(
                        requiresCommit: false,
                        perform: { .text("must not run") }
                    )
                }
            )
            Issue.record("Expected recovery to reject changed trash bytes")
        } catch VaultMutationExecutor.ExecutionError.recoveryStateChanged(
            let path,
            let receivedIdentifier
        ) {
            #expect(path == target.relativePath)
            #expect(receivedIdentifier == identifier)
        } catch {
            Issue.record("Unexpected recovery error: \(error)")
        }

        #expect(await probe.preparationCount == 0)
        #expect(try receipts.activeTransaction()?.identifier == identifier)
        #expect(!FileManager.default.fileExists(atPath: target.url.path))
        #expect(try Data(contentsOf: trashURL) == Data("external trash replacement".utf8))
    }

    private func makeExecutor(
        git: GitRepository,
        dataDirectory: VaultDataDirectory,
        receipts: MutationReceiptStore
    ) -> VaultMutationExecutor {
        VaultMutationExecutor(
            git: git,
            audit: AuditLogger(dataDirectory: dataDirectory),
            processMutationLock: POSIXAdvisoryFileLock(
                url: dataDirectory.lockDirectoryURL
                    .appendingPathComponent("vault-mutations.lock")
            ),
            receipts: receipts
        )
    }

    private func makeOutput(
        target: WritableFileTarget,
        identifier: MutationID,
        data: Data
    ) -> FileOperationOutput {
        FileOperationOutput.text("Created")
            .withMetadata(FileOperationMetadata(
                path: target.relativePath,
                area: .notes,
                revision: FileSnapshot(data: data, modifiedDate: nil).revision,
                mutationID: identifier,
                replayed: false
            ))
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

    private func installFailingCommitHook(at root: String) throws {
        let hook = URL(fileURLWithPath: root)
            .appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nexit 1\n".write(
            to: hook,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: hook.path
        )
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
            throw RecoveryGitInspectionError.commandFailed
        }
        return String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    private enum RecoveryGitInspectionError: Error {
        case commandFailed
    }
}

private actor RecoveryAttemptProbe {
    private(set) var preparationCount = 0
    private(set) var persistenceCount = 0

    func recordPreparation() { preparationCount += 1 }
    func recordPersistence() { persistenceCount += 1 }
}
