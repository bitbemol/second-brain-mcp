import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Vault mutation executor")
struct VaultMutationExecutorTests {
    @Test("Successful storage is committed with centralized metadata")
    func successfulMutation() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let store = VaultCRUDStore(vaultPath: root)
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let executor = makeExecutor(git: git, dataDirectory: dataDirectory)
        let target = try WritableFileTarget.resolve(
            path: "notes/transaction.md",
            format: .markdown,
            vaultPath: root
        )

        let identifier = MutationID()
        let data = Data("body".utf8)
        let result = try await executor.executeIdempotent(
            plan: VaultMutationPlan(
                kind: .create,
                target: target,
                handler: .markdown,
                mutationID: identifier
            ),
            fingerprint: MutationRequestFingerprint(rawValue: "successful-create"),
            prepare: {
                PreparedVaultMutation(
                    requiresCommit: true,
                    perform: {
                        try await store.create(target: target, data: data)
                        return self.output(
                            target: target,
                            identifier: identifier,
                            data: data,
                            text: "stored"
                        )
                    }
                )
            }
        )

        #expect(result.metadata?.mutationID == identifier)
        #expect(try runGit(["log", "-1", "--pretty=%s"], at: root) ==
            "[SecondBrainMCP] Created markdown: notes/transaction.md "
                + "[mutation \(identifier.rawValue)]\n")
        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
    }

    @Test("Storage failures pass through without Git failure wrapping")
    func storageFailure() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let store = VaultCRUDStore(vaultPath: root)
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let executor = makeExecutor(git: git, dataDirectory: dataDirectory)
        let target = try WritableFileTarget.resolve(
            path: "notes/existing.md",
            format: .markdown,
            vaultPath: root
        )
        try Data("existing".utf8).write(to: target.url)

        await #expect(throws: VaultCRUDStore.StoreError.self) {
            let identifier = MutationID()
            _ = try await executor.executeIdempotent(
                plan: VaultMutationPlan(
                    kind: .create,
                    target: target,
                    handler: .markdown,
                    mutationID: identifier
                ),
                fingerprint: MutationRequestFingerprint(rawValue: "storage-failure"),
                prepare: {
                    PreparedVaultMutation(
                        requiresCommit: true,
                        perform: {
                            try await store.create(
                                target: target,
                                data: Data("replacement".utf8)
                            )
                            return self.output(
                                target: target,
                                identifier: identifier,
                                data: Data("replacement".utf8),
                                text: "must not return"
                            )
                        }
                    )
                }
            )
        }
    }

    @Test("Git failures report that persistence already succeeded")
    func gitFailure() async throws {
        let root = try makeVault()
        let store = VaultCRUDStore(vaultPath: root)
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let executor = makeExecutor(
            git: GitRepository(repoPath: root),
            dataDirectory: dataDirectory
        )
        let target = try WritableFileTarget.resolve(
            path: "notes/uncommitted.md",
            format: .markdown,
            vaultPath: root
        )

        do {
            let identifier = MutationID()
            let data = Data("persisted".utf8)
            _ = try await executor.executeIdempotent(
                plan: VaultMutationPlan(
                    kind: .create,
                    target: target,
                    handler: .markdown,
                    mutationID: identifier
                ),
                fingerprint: MutationRequestFingerprint(rawValue: "git-failure"),
                prepare: {
                    PreparedVaultMutation(
                        requiresCommit: true,
                        perform: {
                            try await store.create(target: target, data: data)
                            return self.output(
                                target: target,
                                identifier: identifier,
                                data: data,
                                text: "persisted"
                            )
                        }
                    )
                }
            )
            Issue.record("Expected Git sequencing to fail")
        } catch let error as VaultMutationExecutor.ExecutionError {
            guard case .gitCommitFailed(let path, _, _) = error else {
                Issue.record("Expected a post-persistence Git failure")
                return
            }
            #expect(path == target.relativePath)
        }

        #expect(FileManager.default.fileExists(atPath: target.url.path))
        let audit = try String(
            contentsOf: dataDirectory.auditLogURL,
            encoding: .utf8
        )
        #expect(audit.contains("git commit failed"))
    }

    @Test("Cancellation after persistence does not interrupt the Git commit")
    func postPersistenceCancellationStillCommits() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let store = VaultCRUDStore(vaultPath: root)
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let executor = makeExecutor(git: git, dataDirectory: dataDirectory)
        let target = try WritableFileTarget.resolve(
            path: "notes/canceled-after-write.md",
            format: .markdown,
            vaultPath: root
        )

        let identifier = MutationID()
        let data = Data("persisted".utf8)
        let task = Task {
            try await executor.executeIdempotent(
                plan: VaultMutationPlan(
                    kind: .create,
                    target: target,
                    handler: .markdown,
                    mutationID: identifier
                ),
                fingerprint: MutationRequestFingerprint(rawValue: "cancel-after-write"),
                prepare: {
                    PreparedVaultMutation(
                        requiresCommit: true,
                        perform: {
                            try await store.create(target: target, data: data)
                            withUnsafeCurrentTask { $0?.cancel() }
                            return self.output(
                                target: target,
                                identifier: identifier,
                                data: data,
                                text: "persisted"
                            )
                        }
                    )
                }
            )
        }
        _ = try await task.value

        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
        #expect(
            try runGit(["show", "--pretty=format:", "--name-only", "HEAD"], at: root)
                .contains("notes/canceled-after-write.md")
        )
    }

    @Test("An identical mutation ID replays its durable result without preparing again")
    func identicalRetryReplaysReceipt() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let store = VaultCRUDStore(vaultPath: root)
        let executor = VaultMutationExecutor(
            git: git,
            audit: AuditLogger(dataDirectory: dataDirectory),
            processMutationLock: POSIXAdvisoryFileLock(
                url: dataDirectory.lockDirectoryURL
                    .appendingPathComponent("vault-mutations.lock")
            ),
            receipts: MutationReceiptStore(dataDirectory: dataDirectory)
        )
        let target = try WritableFileTarget.resolve(
            path: "notes/replay.md",
            format: .markdown,
            vaultPath: root
        )
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "same-request")
        let probe = MutationAttemptProbe()
        let plan = VaultMutationPlan(
            kind: .create,
            target: target,
            handler: .markdown,
            mutationID: identifier
        )

        let execute = { @Sendable in
            try await executor.executeIdempotent(
                plan: plan,
                fingerprint: fingerprint,
                prepare: {
                    await probe.recordPreparation()
                    let data = Data("once".utf8)
                    let output = FileOperationOutput.text("Created replay.md")
                        .withMetadata(FileOperationMetadata(
                            path: target.relativePath,
                            area: .notes,
                            revision: FileSnapshot(
                                data: data,
                                modifiedDate: nil
                            ).revision,
                            mutationID: identifier,
                            replayed: false
                        ))
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
        }

        let original = try await execute()
        #expect(try MutationReceiptStore(dataDirectory: dataDirectory)
            .activeTransaction() == nil)
        let replay = try await execute()

        #expect(original.metadata?.replayed == false)
        #expect(replay.metadata?.replayed == true)
        #expect(replay.metadata?.mutationID == identifier)
        #expect(await probe.preparationCount == 1)
        #expect(await probe.persistenceCount == 1)
        #expect(
            try runGit(["rev-list", "--count", "HEAD", "--", target.relativePath], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        )
    }

    @Test("An unfinished durable intent is never applied again")
    func unfinishedIntentFailsConservatively() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "interrupted-request")
        try receipts.saveInProgress(
            identifier: identifier,
            fingerprint: fingerprint
        )
        try receipts.saveActiveTransaction(
            identifier: identifier,
            fingerprint: fingerprint
        )
        let executor = makeExecutor(
            git: git,
            dataDirectory: dataDirectory,
            receipts: receipts
        )
        let target = try WritableFileTarget.resolve(
            path: "notes/unknown.md",
            format: .markdown,
            vaultPath: root
        )
        let probe = MutationAttemptProbe()

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
            Issue.record("Expected an outcome-unknown failure")
        } catch VaultMutationExecutor.ExecutionError.recoveryRequired(let received) {
            #expect(received == identifier)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await probe.preparationCount == 0)
        #expect(!FileManager.default.fileExists(atPath: target.url.path))
    }

    @Test("A mutation ID cannot be reused for different request bytes")
    func identifierReuseIsRejected() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let identifier = MutationID()
        let firstFingerprint = MutationRequestFingerprint(rawValue: "first")
        let target = try WritableFileTarget.resolve(
            path: "notes/reused-id.md",
            format: .markdown,
            vaultPath: root
        )
        let executor = makeExecutor(
            git: git,
            dataDirectory: dataDirectory,
            receipts: receipts
        )
        let plan = VaultMutationPlan(
            kind: .create,
            target: target,
            handler: .markdown,
            mutationID: identifier
        )
        let output = FileOperationOutput.text("No-op")
            .withMetadata(FileOperationMetadata(
                path: target.relativePath,
                area: .notes,
                revision: nil,
                mutationID: identifier,
                replayed: false
            ))

        _ = try await executor.executeIdempotent(
            plan: plan,
            fingerprint: firstFingerprint,
            prepare: {
                PreparedVaultMutation(
                    requiresCommit: false,
                    perform: { output }
                )
            }
        )

        await #expect(throws: MutationReceiptStore.ReceiptError.self) {
            _ = try await executor.executeIdempotent(
                plan: plan,
                fingerprint: MutationRequestFingerprint(rawValue: "different"),
                prepare: {
                    PreparedVaultMutation(
                        requiresCommit: false,
                        perform: { output }
                    )
                }
            )
        }
    }

    @Test("A Git failure blocks other mutations and exact retry commits without persisting twice")
    func gitFailureRecoversWithCommitOnlyRetry() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        try installFailingCommitHook(at: root)
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let store = VaultCRUDStore(vaultPath: root)
        let executor = VaultMutationExecutor(
            git: git,
            audit: AuditLogger(dataDirectory: dataDirectory),
            processMutationLock: POSIXAdvisoryFileLock(
                url: dataDirectory.lockDirectoryURL
                    .appendingPathComponent("vault-mutations.lock")
            ),
            receipts: receipts
        )
        let target = try WritableFileTarget.resolve(
            path: "notes/git-failure-retry.md",
            format: .markdown,
            vaultPath: root
        )
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "git-failure")
        let probe = MutationAttemptProbe()
        let plan = VaultMutationPlan(
            kind: .create,
            target: target,
            handler: .markdown,
            mutationID: identifier
        )
        let execute = { @Sendable in
            try await executor.executeIdempotent(
                plan: plan,
                fingerprint: fingerprint,
                prepare: {
                    await probe.recordPreparation()
                    let data = Data("persisted once".utf8)
                    let output = FileOperationOutput.text("Created")
                        .withMetadata(FileOperationMetadata(
                            path: target.relativePath,
                            area: .notes,
                            revision: FileSnapshot(
                                data: data,
                                modifiedDate: nil
                            ).revision,
                            mutationID: identifier,
                            replayed: false
                        ))
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
        }

        do {
            _ = try await execute()
            Issue.record("Expected the commit hook to fail")
        } catch VaultMutationExecutor.ExecutionError.gitCommitFailed(
            let path,
            let receivedIdentifier,
            _
        ) {
            #expect(path == target.relativePath)
            #expect(receivedIdentifier == identifier)
        } catch {
            Issue.record("Unexpected initial failure: \(error)")
        }

        let blockedIdentifier = MutationID()
        let blockedTarget = try WritableFileTarget.resolve(
            path: "notes/must-wait.md",
            format: .markdown,
            vaultPath: root
        )
        let blockedProbe = MutationAttemptProbe()
        do {
            _ = try await executor.executeIdempotent(
                plan: VaultMutationPlan(
                    kind: .create,
                    target: blockedTarget,
                    handler: .markdown,
                    mutationID: blockedIdentifier
                ),
                fingerprint: MutationRequestFingerprint(rawValue: "different"),
                prepare: {
                    await blockedProbe.recordPreparation()
                    return PreparedVaultMutation(
                        requiresCommit: false,
                        perform: { .text("must not run") }
                    )
                }
            )
            Issue.record("Expected the active transaction to block a different mutation")
        } catch VaultMutationExecutor.ExecutionError.recoveryRequired(
            let active
        ) {
            #expect(active == identifier)
        } catch {
            Issue.record("Unexpected blocking error: \(error)")
        }

        #expect(await blockedProbe.preparationCount == 0)
        #expect(!FileManager.default.fileExists(atPath: blockedTarget.url.path))

        try removeFailingCommitHook(at: root)
        let recovered = try await execute()

        #expect(recovered.metadata?.replayed == true)
        #expect(recovered.metadata?.mutationID == identifier)
        #expect(await probe.preparationCount == 1)
        #expect(await probe.persistenceCount == 1)
        #expect(
            try String(contentsOf: target.url, encoding: .utf8) == "persisted once"
        )
        #expect(try receipts.activeTransaction() == nil)
        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
        #expect(
            try runGit(["rev-list", "--count", "HEAD", "--", target.relativePath], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        )

        let audit = try String(contentsOf: dataDirectory.auditLogURL, encoding: .utf8)
        #expect(audit.contains("recovered git commit after prior failure"))
    }

    @Test("A completed receipt lets a stale active marker be cleared safely")
    func completedReceiptClearsStaleActiveMarker() async throws {
        let root = try makeVault()
        let git = GitRepository(repoPath: root)
        try await git.ensureRepository()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "completed")
        let target = try WritableFileTarget.resolve(
            path: "notes/completed.md",
            format: .markdown,
            vaultPath: root
        )
        let output = FileOperationOutput.text("Created")
            .withMetadata(FileOperationMetadata(
                path: target.relativePath,
                area: .notes,
                revision: FileSnapshot(
                    data: Data("complete".utf8),
                    modifiedDate: nil
                ).revision,
                mutationID: identifier,
                replayed: false
            ))
        try receipts.save(
            identifier: identifier,
            fingerprint: fingerprint,
            output: output
        )
        try receipts.saveActiveTransaction(
            identifier: identifier,
            fingerprint: fingerprint
        )
        let executor = VaultMutationExecutor(
            git: git,
            audit: AuditLogger(dataDirectory: dataDirectory),
            processMutationLock: POSIXAdvisoryFileLock(
                url: dataDirectory.lockDirectoryURL
                    .appendingPathComponent("vault-mutations.lock")
            ),
            receipts: receipts
        )
        let probe = MutationAttemptProbe()

        let replay = try await executor.executeIdempotent(
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

        #expect(replay.metadata?.replayed == true)
        #expect(await probe.preparationCount == 0)
        #expect(try receipts.activeTransaction() == nil)
    }

    @Test("Independent executors serialize the shared Git working tree")
    func independentExecutorsShareProcessLock() async throws {
        let root = try makeVault()
        let initialGit = GitRepository(repoPath: root)
        try await initialGit.ensureRepository()
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let lock = POSIXAdvisoryFileLock(
            url: dataDirectory.lockDirectoryURL
                .appendingPathComponent("vault-mutations.lock"),
            retryNanoseconds: 1_000_000
        )
        let firstExecutor = VaultMutationExecutor(
            git: GitRepository(repoPath: root),
            audit: AuditLogger(dataDirectory: dataDirectory),
            processMutationLock: lock,
            receipts: MutationReceiptStore(dataDirectory: dataDirectory)
        )
        let secondExecutor = VaultMutationExecutor(
            git: GitRepository(repoPath: root),
            audit: AuditLogger(dataDirectory: dataDirectory),
            processMutationLock: lock,
            receipts: MutationReceiptStore(dataDirectory: dataDirectory)
        )
        let firstStore = VaultCRUDStore(vaultPath: root)
        let secondStore = VaultCRUDStore(vaultPath: root)
        let firstTarget = try WritableFileTarget.resolve(
            path: "notes/first-process.md",
            format: .markdown,
            vaultPath: root
        )
        let secondTarget = try WritableFileTarget.resolve(
            path: "notes/second-process.md",
            format: .markdown,
            vaultPath: root
        )
        let probe = MutationCriticalSectionProbe()

        let firstIdentifier = MutationID()
        let firstData = Data("first".utf8)
        let secondIdentifier = MutationID()
        let secondData = Data("second".utf8)
        async let first = firstExecutor.executeIdempotent(
            plan: VaultMutationPlan(
                kind: .create,
                target: firstTarget,
                handler: .markdown,
                mutationID: firstIdentifier
            ),
            fingerprint: MutationRequestFingerprint(rawValue: "first-process"),
            prepare: {
                PreparedVaultMutation(
                    requiresCommit: true,
                    perform: {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(30))
                        try await firstStore.create(
                            target: firstTarget,
                            data: firstData
                        )
                        await probe.leave()
                        return self.output(
                            target: firstTarget,
                            identifier: firstIdentifier,
                            data: firstData,
                            text: "first"
                        )
                    }
                )
            }
        )
        async let second = secondExecutor.executeIdempotent(
            plan: VaultMutationPlan(
                kind: .create,
                target: secondTarget,
                handler: .markdown,
                mutationID: secondIdentifier
            ),
            fingerprint: MutationRequestFingerprint(rawValue: "second-process"),
            prepare: {
                PreparedVaultMutation(
                    requiresCommit: true,
                    perform: {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(30))
                        try await secondStore.create(
                            target: secondTarget,
                            data: secondData
                        )
                        await probe.leave()
                        return self.output(
                            target: secondTarget,
                            identifier: secondIdentifier,
                            data: secondData,
                            text: "second"
                        )
                    }
                )
            }
        )
        _ = try await (first, second)

        #expect(await probe.maximumConcurrency == 1)
        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
    }

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "VaultMutationExecutorTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeExecutor(
        git: GitRepository,
        dataDirectory: VaultDataDirectory
    ) -> VaultMutationExecutor {
        makeExecutor(
            git: git,
            dataDirectory: dataDirectory,
            receipts: MutationReceiptStore(dataDirectory: dataDirectory)
        )
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

    private func output(
        target: WritableFileTarget,
        identifier: MutationID,
        data: Data,
        text: String
    ) -> FileOperationOutput {
        FileOperationOutput.text(text).withMetadata(FileOperationMetadata(
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
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitInspectionError.commandFailed
        }
        return String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
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

    private func removeFailingCommitHook(at root: String) throws {
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: root)
                .appendingPathComponent(".git/hooks/pre-commit")
        )
    }

    private enum GitInspectionError: Error {
        case commandFailed
    }
}

private actor MutationAttemptProbe {
    private(set) var preparationCount = 0
    private(set) var persistenceCount = 0

    func recordPreparation() {
        preparationCount += 1
    }

    func recordPersistence() {
        persistenceCount += 1
    }
}

private actor MutationCriticalSectionProbe {
    private var active = 0
    private(set) var maximumConcurrency = 0

    func enter() {
        active += 1
        maximumConcurrency = max(maximumConcurrency, active)
    }

    func leave() {
        active -= 1
    }
}
