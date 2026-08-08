import Foundation
import Testing
@testable import SecondBrainMCP

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
            .contains("Initial commit"))
    }

    @Test("An exact retry completes Git after the directory was already moved")
    func recoversGitFailure() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root)
        let hook = URL(fileURLWithPath: root + "/.git/hooks/pre-commit")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hook.path
        )
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

        try FileManager.default.removeItem(at: hook)
        let recovered = try await runtime.directories.move(request)
        #expect(recovered.metadata?.replayed == true)
        #expect(try git(["status", "--porcelain"], root: root).isEmpty)
        #expect(try git(["rev-list", "--count", "HEAD"], root: root)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    @Test("The scoped move commit preserves unrelated staged work")
    func preservesUnrelatedIndex() async throws {
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
        #expect(staged.split(separator: "\n").map(String.init) == [
            "notes/unrelated.md",
        ])
        #expect(try git(["show", "--name-only", "--pretty=format:", "HEAD"], root: root)
            .contains("notes/completed/ticket-123/overview.md"))
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
            operationIdentifier: DirectoryMoveToolDefinition.name,
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
                identity: identity
            )
        )
        try receipts.saveActiveTransaction(
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

    private enum TestFailure: Error { case git }
}
