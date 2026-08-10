import Darwin
import Foundation
import Testing
@testable import second_brain_mcp

@Suite("Vault directory move service", .serialized)
struct VaultDirectoryMoveServiceTests {
    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "VaultDirectoryMoveServiceTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes/in-progress/ticket-123/research",
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        try "# Ticket\nunique subtree search sentinel".write(
            toFile: root + "/notes/in-progress/ticket-123/overview.md",
            atomically: true,
            encoding: .utf8
        )
        try "nested bytes".write(
            toFile: root + "/notes/in-progress/ticket-123/research/context.log",
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    private func git(_ arguments: [String], root: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestFailure.git }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test("One move preserves a nested subtree, commits once, and search sees its new prefix")
    func recursiveMoveAndSearch() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let request = MoveDirectoryRequest(
            mutationID: MutationID(),
            sourcePath: "notes//in-progress/ticket-123/",
            destinationPath: "notes/completed/ticket-123"
        )
        let output = try await runtime.directories.move(request)

        #expect(!FileManager.default.fileExists(
            atPath: root + "/notes/in-progress/ticket-123"
        ))
        #expect(try String(
            contentsOfFile: root + "/notes/completed/ticket-123/research/context.log",
            encoding: .utf8
        ) == "nested bytes")
        #expect(output.metadata?.sourcePath == "notes/in-progress/ticket-123")
        #expect(output.metadata?.path == "notes/completed/ticket-123")
        #expect(output.metadata?.replayed == false)

        let search = try await runtime.search.search(VaultSearchRequest(
            query: "unique subtree search sentinel",
            strategy: .exact,
            fields: [.content],
            formats: [.markdown],
            areas: [.notes],
            pathPrefix: "notes/completed/ticket-123/",
            limit: 20
        ))
        #expect(search.results.map(\.path) == [
            "notes/completed/ticket-123/overview.md",
        ])
        #expect(try git(["status", "--porcelain"], root: root).isEmpty)

        let commitCount = try git(["rev-list", "--count", "HEAD"], root: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(commitCount == "2")
        let replay = try await runtime.directories.move(request)
        #expect(replay.metadata?.replayed == true)
        #expect(try git(["rev-list", "--count", "HEAD"], root: root)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    @Test("No-clobber, self-subtree, non-directory, and reference moves fail safely")
    func rejectsUnsafeMoves() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: root + "/notes/completed/ticket-123",
            withIntermediateDirectories: true
        )
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)

        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(
                mutationID: MutationID(),
                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ))
        }
        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(
                mutationID: MutationID(),
                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/Ticket.app/ticket-123"
            ))
        }
        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(
                mutationID: MutationID(),
                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/in-progress/ticket-123/inside"
            ))
        }
        await #expect(throws: FileRoutingError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(
                mutationID: MutationID(),
                sourcePath: "references/books",
                destinationPath: "notes/completed/books"
            ))
        }
        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(
                mutationID: MutationID(),
                sourcePath: "notes/in-progress/ticket-123/overview.md",
                destinationPath: "notes/completed/overview"
            ))
        }
        #expect(FileManager.default.fileExists(
            atPath: root + "/notes/in-progress/ticket-123/overview.md"
        ))
    }

    @Test("Read-only runtime refuses directory moves without initializing Git")
    func readOnly() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root, readOnly: true)
        await #expect(throws: FileRoutingError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(
                mutationID: MutationID(),
                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: root + "/.git"))
        #expect(FileManager.default.fileExists(
            atPath: root + "/notes/in-progress/ticket-123"
        ))
    }

    @Test("An untracked credential inside the subtree is never moved or committed")
    func rejectsSensitiveSubtree() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        try "api_key=abcdefghijklmnop1234567890".write(
            toFile: root + "/notes/in-progress/ticket-123/private.txt",
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: SensitiveContentPolicy.Violation.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(
                mutationID: MutationID(),
                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ))
        }
        #expect(FileManager.default.fileExists(
            atPath: root + "/notes/in-progress/ticket-123/private.txt"
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root + "/notes/completed/ticket-123"
        ))
        #expect(try git(["log", "-1", "--pretty=%s"], root: root)
            .contains("Vault snapshot"))
    }

    @Test("An existing HAR with structured credentials is never moved or committed")
    func rejectsCredentialBearingHAR() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let har = #"{"log":{"entries":[{"request":{"headers":[{"name":"Authorization","value":"short-secret"}]}}]}}"#
        try Data(har.utf8).write(
            to: URL(fileURLWithPath:
                root + "/notes/in-progress/ticket-123/captured.har")
        )

        await #expect(throws: PersistedFileSecurityPolicy.Violation.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(
                mutationID: MutationID(),
                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ))
        }
        #expect(FileManager.default.fileExists(
            atPath: root + "/notes/in-progress/ticket-123/captured.har"
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root + "/notes/completed/ticket-123"
        ))
        #expect(try git(["rev-list", "--count", "HEAD"], root: root)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test("An obvious unknown text file cannot become binary through invalid UTF-8")
    func rejectsInvalidUnknownTextEncoding() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        var bytes = Data(
            ("Bearer " + String(repeating: "v", count: 32)).utf8
        )
        bytes.append(0xff)
        try bytes.write(to: URL(fileURLWithPath:
            root + "/notes/in-progress/ticket-123/settings.yaml"))

        await #expect(throws: TextFileSupport.TextError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(
                mutationID: MutationID(),
                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ))
        }
        #expect(FileManager.default.fileExists(
            atPath: root + "/notes/in-progress/ticket-123/settings.yaml"
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root + "/notes/completed/ticket-123"
        ))
        #expect(try git(["rev-list", "--count", "HEAD"], root: root)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test("Git mode validation follows Git's owner-execute convention")
    func preservesGroupAndOtherExecutePermissions() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let modes: [(name: String, mode: mode_t)] = [
            ("group-executable.sh", 0o610),
            ("other-executable.sh", 0o601),
        ]
        for value in modes {
            let path = root + "/notes/in-progress/ticket-123/" + value.name
            try "safe executable bytes".write(
                toFile: path,
                atomically: true,
                encoding: .utf8
            )
            #expect(Darwin.chmod(path, value.mode) == 0)
        }

        _ = try await runtime.directories.move(MoveDirectoryRequest(
            mutationID: MutationID(),
            sourcePath: "notes/in-progress/ticket-123",
            destinationPath: "notes/completed/ticket-123"
        ))

        for value in modes {
            let path = "notes/completed/ticket-123/" + value.name
            #expect(try git(["ls-tree", "HEAD", "--", path], root: root)
                .hasPrefix("100644 blob "))
        }
        #expect(try git(["status", "--porcelain"], root: root).isEmpty)
    }

    @Test("An exact retry records a snapshot after the directory was already moved")
    func recoversSnapshotFailure() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let reference = try git(["symbolic-ref", "HEAD"], root: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let referenceLock = URL(fileURLWithPath: root + "/.git/" + reference + ".lock")
        try FileManager.default.createDirectory(
            at: referenceLock.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("locked".utf8).write(to: referenceLock)
        let request = MoveDirectoryRequest(
            mutationID: MutationID(),
            sourcePath: "notes/in-progress/ticket-123",
            destinationPath: "notes/completed/ticket-123"
        )

        await #expect(throws: VaultDirectoryMoveService.ExecutionError.self) {
            _ = try await runtime.directories.move(request)
        }
        #expect(!FileManager.default.fileExists(
            atPath: root + "/notes/in-progress/ticket-123"
        ))
        #expect(FileManager.default.fileExists(
            atPath: root + "/notes/completed/ticket-123/overview.md"
        ))

        try FileManager.default.removeItem(at: referenceLock)
        let recovered = try await runtime.directories.move(request)
        #expect(recovered.metadata?.replayed == true)
        #expect(try git(["status", "--porcelain"], root: root).isEmpty)
        #expect(try git(["rev-list", "--count", "HEAD"], root: root)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    @Test("A move snapshot coalesces unrelated pending note work")
    func coalescesUnrelatedNoteWork() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        try "unrelated".write(
            toFile: root + "/notes/unrelated.md",
            atomically: true,
            encoding: .utf8
        )
        _ = try git(["add", "--", "notes/unrelated.md"], root: root)

        _ = try await runtime.directories.move(MoveDirectoryRequest(
            mutationID: MutationID(),
            sourcePath: "notes/in-progress/ticket-123",
            destinationPath: "notes/completed/ticket-123"
        ))
        let staged = try git(["diff", "--cached", "--name-only"], root: root)
        #expect(staged.isEmpty)
        let snapshot = try git(
            ["show", "--name-only", "--pretty=format:", "HEAD"],
            root: root
        )
        #expect(snapshot.contains("notes/completed/ticket-123/overview.md"))
        #expect(snapshot.contains("notes/unrelated.md"))
    }

    @Test("A crash after rename is recovered only for the recorded source inode")
    func recoversInterruptedRenameFromIdentity() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let request = MoveDirectoryRequest(
            mutationID: MutationID(),
            sourcePath: "notes/in-progress/ticket-123",
            destinationPath: "notes/completed/ticket-123"
        )
        let fingerprint = try MutationRequestFingerprint.make(
            operationIdentifier: MoveDirectoryRequest.operationIdentifier,
            request: request
        )
        let source = try NotesDirectoryTarget.resolve(
            path: request.sourcePath,
            vaultPath: root
        )
        let destination = try NotesDirectoryTarget.resolve(
            path: request.destinationPath,
            vaultPath: root
        )
        let tree = DirectoryTreeStore(vaultPath: root)
        let identity: DirectoryTreeStore.Identity
        guard case .directory(let observed) = try tree.state(of: source) else {
            Issue.record("Expected source directory")
            return
        }
        identity = observed
        let summary = try DirectoryMoveSecurityPreflight.validate(source).summary
        let dataDirectory = try VaultDataDirectory.prepare(
            vaultPath: root,
            migrateLegacyData: false
        )
        let receipts = MutationReceiptStore(dataDirectory: dataDirectory)
        try receipts.saveInProgress(
            identifier: request.mutationID,
            fingerprint: fingerprint,
            recoveryEvidence: .directoryMoveIntent(
                sourcePath: request.sourcePath,
                destinationPath: request.destinationPath,
                identity: identity,
                summary: summary
            )
        )
        try receipts.markPersistenceStarted(
            identifier: request.mutationID,
            fingerprint: fingerprint
        )
        _ = try tree.move(
            source: source,
            destination: destination,
            expectedIdentity: identity
        )

        let recovered = try await runtime.directories.move(request)
        #expect(recovered.metadata?.replayed == true)
        #expect(try git(["status", "--porcelain"], root: root).isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: root + "/notes/completed/ticket-123/overview.md"
        ))
    }

    @Test("A pre-persistence directory intent is safely restarted")
    func clearsEvidenceOnlyIntent() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let request = MoveDirectoryRequest(
            mutationID: MutationID(),
            sourcePath: "notes/in-progress/ticket-123",
            destinationPath: "notes/completed/ticket-123"
        )
        let fingerprint = try MutationRequestFingerprint.make(
            operationIdentifier: MoveDirectoryRequest.operationIdentifier,
            request: request
        )
        let tree = DirectoryTreeStore(vaultPath: root)
        let source = try NotesDirectoryTarget.resolve(
            path: request.sourcePath,
            vaultPath: root
        )
        guard case .directory(let identity) = try tree.state(of: source) else {
            Issue.record("Expected source directory")
            return
        }
        let summary = try DirectoryMoveSecurityPreflight.validate(source).summary
        let receipts = MutationReceiptStore(dataDirectory: try VaultDataDirectory.prepare(
            vaultPath: root,
            migrateLegacyData: false
        ))
        try receipts.saveInProgress(
            identifier: request.mutationID,
            fingerprint: fingerprint,
            recoveryEvidence: .directoryMoveIntent(
                sourcePath: request.sourcePath,
                destinationPath: request.destinationPath,
                identity: identity,
                summary: summary
            )
        )

        let result = try await runtime.directories.move(request)
        #expect(result.metadata?.replayed == false)
        #expect(FileManager.default.fileExists(
            atPath: root + "/notes/completed/ticket-123/overview.md"
        ))
    }

    @Test("A completed directory move replays without moving again")
    func completedMoveReplays() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let request = MoveDirectoryRequest(
            mutationID: MutationID(),
            sourcePath: "notes/in-progress/ticket-123",
            destinationPath: "notes/completed/ticket-123"
        )

        _ = try await runtime.directories.move(request)
        let replay = try await runtime.directories.move(request)

        #expect(replay.metadata?.replayed == true)
    }

    @Test("A prior commit mentioning the mutation ID cannot suppress a snapshot")
    func doesNotInspectCommitMessagesForReplay() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let identifier = MutationID()
        try "prior edit".write(
            toFile: root + "/notes/in-progress/ticket-123/overview.md",
            atomically: true,
            encoding: .utf8
        )
        _ = try git(["add", "--", "notes/in-progress/ticket-123/overview.md"], root: root)
        _ = try git([
            "commit", "-m", "manual [mutation \(identifier.rawValue)]",
        ], root: root)
        let before = try git(["rev-list", "--count", "HEAD"], root: root)

        _ = try await runtime.directories.move(MoveDirectoryRequest(
            mutationID: identifier,
            sourcePath: "notes/in-progress/ticket-123",
            destinationPath: "notes/completed/ticket-123"
        ))
        let after = try git(["rev-list", "--count", "HEAD"], root: root)
        #expect(Int(after.trimmingCharacters(in: .whitespacesAndNewlines))
            == Int(before.trimmingCharacters(in: .whitespacesAndNewlines))! + 1)
        #expect(try git(["status", "--porcelain"], root: root).isEmpty)
    }

    @Test(
        "Move recovery refuses any descendant state change",
        arguments: RecoveredSubtreeMutation.allCases
    )
    func recoveryBindsExactSubtree(
        mutation: RecoveredSubtreeMutation
    ) async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let reference = try git(["symbolic-ref", "HEAD"], root: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let referenceLock = URL(fileURLWithPath: root + "/.git/" + reference + ".lock")
        try Data("locked".utf8).write(to: referenceLock)
        let request = MoveDirectoryRequest(
            mutationID: MutationID(),
            sourcePath: "notes/in-progress/ticket-123",
            destinationPath: "notes/completed/ticket-123"
        )
        await #expect(throws: VaultDirectoryMoveService.ExecutionError.self) {
            _ = try await runtime.directories.move(request)
        }
        try FileManager.default.removeItem(at: referenceLock)
        let destination = root + "/notes/completed/ticket-123"
        switch mutation {
        case .change:
            try "changed safe bytes".write(
                toFile: destination + "/overview.md",
                atomically: true,
                encoding: .utf8
            )
        case .add:
            try "added safe bytes".write(
                toFile: destination + "/added.md",
                atomically: true,
                encoding: .utf8
            )
        case .delete:
            try FileManager.default.removeItem(
                atPath: destination + "/research/context.log"
            )
        case .chmod:
            #expect(Darwin.chmod(destination + "/overview.md", 0o755) == 0)
        case .addEmptyDirectory:
            try FileManager.default.createDirectory(
                atPath: destination + "/new-empty",
                withIntermediateDirectories: false
            )
        }

        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(request)
        }
        #expect(try git(["rev-list", "--count", "HEAD"], root: root)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test("Hidden and package descendants are refused before rename")
    func rejectsHiddenAndPackageDescendants() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let hidden = root + "/notes/in-progress/ticket-123/.gitignore"
        try "*.md".write(toFile: hidden, atomically: true, encoding: .utf8)
        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(
                mutationID: MutationID(),
                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ))
        }
        try FileManager.default.removeItem(atPath: hidden)
        try FileManager.default.createDirectory(
            atPath: root + "/notes/in-progress/ticket-123/Nested.app",
            withIntermediateDirectories: true
        )
        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(
                mutationID: MutationID(),
                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ))
        }
        try FileManager.default.removeItem(
            atPath: root + "/notes/in-progress/ticket-123/Nested.app"
        )
        let flagged = root + "/notes/in-progress/ticket-123/flagged"
        try FileManager.default.createDirectory(
            atPath: flagged,
            withIntermediateDirectories: false
        )
        #expect(Darwin.chflags(flagged, UInt32(UF_HIDDEN)) == 0)
        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(
                mutationID: MutationID(),
                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ))
        }
    }

    @Test("All subtree bytes are charged from stable descriptors")
    func enforcesAggregateSubtreeBytes() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = try NotesDirectoryTarget.resolve(
            path: "notes/in-progress/ticket-123",
            vaultPath: root
        )
        #expect(throws: DirectoryMoveError.self) {
            _ = try DirectoryMoveSecurityPreflight.validate(
                source,
                maximumSubtreeBytes: 4
            )
        }
    }

    @Test("Aggregate manifest paths are bounded independently from file bytes")
    func enforcesAggregateManifestPathBytes() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = try NotesDirectoryTarget.resolve(
            path: "notes/in-progress/ticket-123",
            vaultPath: root
        )
        #expect(throws: DirectoryMoveError.self) {
            _ = try DirectoryMoveSecurityPreflight.validate(
                source,
                maximumManifestPathBytes: 8
            )
        }
    }

    @Test("Created-parent cleanup never removes a substituted directory")
    func cleanupUsesCreatedIdentity() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        enum Injected: Error { case stop }
        let tree = DirectoryTreeStore(vaultPath: root) {
            try FileManager.default.moveItem(
                atPath: root + "/notes/new",
                toPath: root + "/notes/displaced"
            )
            try FileManager.default.createDirectory(
                atPath: root + "/notes/new",
                withIntermediateDirectories: false
            )
            throw Injected.stop
        }
        let source = try NotesDirectoryTarget.resolve(
            path: "notes/in-progress/ticket-123",
            vaultPath: root
        )
        let destination = try NotesDirectoryTarget.resolve(
            path: "notes/new/parent/ticket-123",
            vaultPath: root
        )
        guard case .directory(let identity) = try tree.state(of: source) else {
            Issue.record("Expected source")
            return
        }
        #expect(throws: Injected.self) {
            _ = try tree.move(
                source: source,
                destination: destination,
                expectedIdentity: identity
            )
        }
        #expect(FileManager.default.fileExists(atPath: root + "/notes/new"))
        #expect(FileManager.default.fileExists(atPath: root + "/notes/displaced"))
        #expect(FileManager.default.fileExists(atPath: source.url.path))
    }

    @Test("Birthtime participates in directory recovery identity")
    func birthtimeStrengthensIdentity() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let tree = DirectoryTreeStore(vaultPath: root)
        let source = try NotesDirectoryTarget.resolve(
            path: "notes/in-progress/ticket-123",
            vaultPath: root
        )
        let destination = try NotesDirectoryTarget.resolve(
            path: "notes/completed/ticket-123",
            vaultPath: root
        )
        guard case .directory(let identity) = try tree.state(of: source) else {
            Issue.record("Expected source")
            return
        }
        let wrong = DirectoryTreeStore.Identity(
            device: identity.device,
            inode: identity.inode,
            birthSeconds: identity.birthSeconds,
            birthNanoseconds: identity.birthNanoseconds + 1
        )
        #expect(throws: DirectoryMoveError.self) {
            _ = try tree.move(
                source: source,
                destination: destination,
                expectedIdentity: wrong
            )
        }
        #expect(FileManager.default.fileExists(atPath: source.url.path))
    }

    private enum TestFailure: Error { case git }
}

enum RecoveredSubtreeMutation: String, CaseIterable {
    case change
    case add
    case delete
    case chmod
    case addEmptyDirectory
}
