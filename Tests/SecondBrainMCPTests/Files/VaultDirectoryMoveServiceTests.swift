import Darwin
import Foundation
import Testing
@testable import second_brain_mcp

@Suite(.serialized)
struct `Vault directory move service` {
    private actor DelayedVersioning: VaultVersioning {
        private var started = false
        private var finished = false

        func recordSnapshot() async throws {
            started = true
            try await Task.sleep(for: .milliseconds(100))
            finished = true
        }

        func hasStarted() -> Bool { started }
        func hasFinished() -> Bool { finished }
    }

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

    private func makeRecoveredRuntime(vaultPath: String) async throws -> VaultRuntime {
        let runtime = try await VaultRuntime.bootstrap(vaultPath: vaultPath)
        try await runtime.recoverPendingChanges()
        return runtime
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

    @Test
    func `Cancellation after rename begins does not skip the snapshot`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let versioning = DelayedVersioning()
        let service = VaultDirectoryMoveService(
            vaultPath: root,
            versioning: versioning,
            access: VaultAccessCoordinator(
                lockURL: dataDirectory.lockDirectoryURL
                    .appendingPathComponent("vault-access.lock")
            ),
            readOnly: false
        )
        let task = Task {
            try await service.move(MoveDirectoryRequest(
                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ))
        }

        while !(await versioning.hasStarted()) {
            await Task.yield()
        }
        task.cancel()

        _ = try await task.value
        #expect(await versioning.hasFinished())
        #expect(FileManager.default.fileExists(
            atPath: root + "/notes/completed/ticket-123/overview.md"
        ))
    }

    @Test
    func `One move preserves a nested subtree, commits once, and search sees its new prefix`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await makeRecoveredRuntime(vaultPath: root)
        let request = MoveDirectoryRequest(

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

        let search = try await runtime.search.search(VaultSearchRequest(
            location: .notes,
            query: "unique subtree search sentinel",
            limit: 20
        ))
        #expect(search.results.map(\.path) == [
            "notes/completed/ticket-123/overview.md",
        ])
        #expect(try git(["status", "--porcelain"], root: root).isEmpty)

        let commitCount = try git(["rev-list", "--count", "HEAD"], root: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(commitCount == "2")
    }

    @Test
    func `Empty directory moves remain filesystem-only because Git has no directory objects`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: root + "/notes/in-progress/empty",
            withIntermediateDirectories: true
        )
        let runtime = try await makeRecoveredRuntime(vaultPath: root)
        let before = try git(["rev-list", "--count", "HEAD"], root: root)

        _ = try await runtime.directories.move(MoveDirectoryRequest(

            sourcePath: "notes/in-progress/empty",
            destinationPath: "notes/completed/empty"
        ))

        #expect(!FileManager.default.fileExists(
            atPath: root + "/notes/in-progress/empty"
        ))
        #expect(FileManager.default.fileExists(
            atPath: root + "/notes/completed/empty"
        ))
        #expect(try git(["rev-list", "--count", "HEAD"], root: root) == before)
    }

    @Test
    func `Case-only directory renames are rejected as the same canonical path`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await makeRecoveredRuntime(vaultPath: root)

        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(

                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/in-progress/TICKET-123"
            ))
        }
        #expect(FileManager.default.fileExists(
            atPath: root + "/notes/in-progress/ticket-123"
        ))
    }

    @Test
    func `No-clobber, self-subtree, non-directory, and reference moves fail safely`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: root + "/notes/completed/ticket-123",
            withIntermediateDirectories: true
        )
        let runtime = try await makeRecoveredRuntime(vaultPath: root)

        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(

                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ))
        }
        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(

                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/Ticket.app/ticket-123"
            ))
        }
        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(

                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/in-progress/ticket-123/inside"
            ))
        }
        await #expect(throws: FileRoutingError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(

                sourcePath: "references/books",
                destinationPath: "notes/completed/books"
            ))
        }
        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(

                sourcePath: "notes/in-progress/ticket-123/overview.md",
                destinationPath: "notes/completed/overview"
            ))
        }
        #expect(FileManager.default.fileExists(
            atPath: root + "/notes/in-progress/ticket-123/overview.md"
        ))
    }

    @Test
    func `Read-only runtime refuses directory moves without initializing Git`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root, readOnly: true)
        await #expect(throws: FileRoutingError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(

                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: root + "/.git"))
        #expect(FileManager.default.fileExists(
            atPath: root + "/notes/in-progress/ticket-123"
        ))
    }

    @Test
    func `An untracked credential inside the subtree is never moved or committed`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await makeRecoveredRuntime(vaultPath: root)
        try "api_key=abcdefghijklmnop1234567890".write(
            toFile: root + "/notes/in-progress/ticket-123/private.txt",
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: SensitiveContentPolicy.Violation.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(

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

    @Test
    func `An existing HAR with structured credentials is never moved or committed`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await makeRecoveredRuntime(vaultPath: root)
        let har = #"{"log":{"entries":[{"request":{"headers":[{"name":"Authorization","value":"short-secret"}]}}]}}"#
        try Data(har.utf8).write(
            to: URL(fileURLWithPath:
                root + "/notes/in-progress/ticket-123/captured.har")
        )

        await #expect(throws: PersistedFileSecurityPolicy.Violation.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(

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

    @Test
    func `An obvious unknown text file cannot become binary through invalid UTF-8`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await makeRecoveredRuntime(vaultPath: root)
        var bytes = Data(
            ("Bearer " + String(repeating: "v", count: 32)).utf8
        )
        bytes.append(0xff)
        try bytes.write(to: URL(fileURLWithPath:
            root + "/notes/in-progress/ticket-123/settings.yaml"))

        await #expect(throws: TextFileSupport.TextError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(

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

    @Test
    func `Git mode validation follows Git's owner-execute convention`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await makeRecoveredRuntime(vaultPath: root)
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

    @Test
    func `A move snapshot coalesces unrelated pending note work`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await makeRecoveredRuntime(vaultPath: root)
        try "unrelated".write(
            toFile: root + "/notes/unrelated.md",
            atomically: true,
            encoding: .utf8
        )
        _ = try git(["add", "--", "notes/unrelated.md"], root: root)

        _ = try await runtime.directories.move(MoveDirectoryRequest(

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

    @Test
    func `Hidden and package descendants are refused before rename`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await makeRecoveredRuntime(vaultPath: root)
        let hidden = root + "/notes/in-progress/ticket-123/.gitignore"
        try "*.md".write(toFile: hidden, atomically: true, encoding: .utf8)
        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.directories.move(MoveDirectoryRequest(

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

                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ))
        }
    }

    @Test
    func `All subtree bytes are charged from stable descriptors`() throws {
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

    @Test
    func `Aggregate manifest paths are bounded independently from file bytes`() throws {
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

    @Test
    func `Created-parent cleanup never removes a substituted directory`() throws {
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

    @Test
    func `Birthtime participates in directory recovery identity`() throws {
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
