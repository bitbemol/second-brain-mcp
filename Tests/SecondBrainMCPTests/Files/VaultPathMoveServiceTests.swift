import Darwin
import Foundation
import Testing
@testable import second_brain_mcp

@Suite(.serialized)
struct `Vault path move service` {
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
        let root = NSTemporaryDirectory() + "VaultPathMoveServiceTests-\(UUID().uuidString)"
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
        let service = VaultPathMoveService(
            vaultPath: root,
            supportedFileFormats: Set(FileFormat.allCases.filter { $0 != .pdf }),
            versioning: versioning,
            access: VaultAccessCoordinator(
                lockURL: dataDirectory.lockDirectoryURL
                    .appendingPathComponent("vault-access.lock")
            ),
            readOnly: false
        )
        let task = Task {
            try await service.move(MovePathRequest.directory(
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
    func `File cancellation after rename begins does not skip the snapshot`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let versioning = DelayedVersioning()
        let service = VaultPathMoveService(
            vaultPath: root,
            supportedFileFormats: [.markdown],
            versioning: versioning,
            access: VaultAccessCoordinator(
                lockURL: dataDirectory.lockDirectoryURL
                    .appendingPathComponent("vault-access.lock")
            ),
            readOnly: false
        )
        let source = root + "/notes/in-progress/ticket-123/overview.md"
        let bytes = try Data(contentsOf: URL(fileURLWithPath: source))
        let revision = FileSnapshot(data: bytes, modifiedDate: nil).revision
        let task = Task {
            try await service.move(.file(
                sourcePath: "notes/in-progress/ticket-123/overview.md",
                destinationPath: "notes/completed/overview.md",
                format: .markdown,
                expectedRevision: revision
            ))
        }

        while !(await versioning.hasStarted()) {
            await Task.yield()
        }
        task.cancel()

        _ = try await task.value
        #expect(await versioning.hasFinished())
        #expect(!FileManager.default.fileExists(atPath: source))
        #expect(try Data(
            contentsOf: URL(fileURLWithPath: root + "/notes/completed/overview.md")
        ) == bytes)
    }

    @Test
    func `One move preserves a nested subtree, commits once, and search sees its new prefix`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await makeRecoveredRuntime(vaultPath: root)
        let request = MovePathRequest.directory(

            sourcePath: "notes//in-progress/ticket-123/",
            destinationPath: "notes/completed/ticket-123"
        )
        let output = try await runtime.paths.move(request)

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
    func `A supported file can move atomically without rewriting its bytes`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await makeRecoveredRuntime(vaultPath: root)
        let source = root + "/notes/in-progress/ticket-123/overview.md"
        let original = try Data(contentsOf: URL(fileURLWithPath: source))

        let revision = FileSnapshot(data: original, modifiedDate: nil).revision
        let output = try await runtime.paths.move(MovePathRequest.file(
            sourcePath: "notes/in-progress/ticket-123/overview.md",
            destinationPath: "notes/completed/overview.md",
            format: .markdown,
            expectedRevision: revision
        ))

        #expect(!FileManager.default.fileExists(atPath: source))
        #expect(try Data(
            contentsOf: URL(fileURLWithPath: root + "/notes/completed/overview.md")
        ) == original)
        #expect(output.metadata?.revision == revision)
        #expect(try git(["status", "--porcelain"], root: root).isEmpty)
    }

    @Test
    func `A stale file revision is rejected without moving either version`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await makeRecoveredRuntime(vaultPath: root)
        let relative = "notes/in-progress/ticket-123/overview.md"
        let source = root + "/" + relative
        let stale = FileSnapshot(
            data: try Data(contentsOf: URL(fileURLWithPath: source)),
            modifiedDate: nil
        ).revision
        try "# externally changed".write(
            toFile: source,
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: FileRoutingError.self) {
            _ = try await runtime.paths.move(.file(
                sourcePath: relative,
                destinationPath: "notes/completed/overview.md",
                format: .markdown,
                expectedRevision: stale
            ))
        }

        #expect(try String(contentsOfFile: source, encoding: .utf8)
            == "# externally changed")
        #expect(!FileManager.default.fileExists(
            atPath: root + "/notes/completed/overview.md"
        ))
    }

    @Test
    func `File moves enforce credential format extension and area policies`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runtime = try await makeRecoveredRuntime(vaultPath: root)
        let relative = "notes/in-progress/ticket-123/overview.md"
        let source = root + "/" + relative
        let secret = "Bearer " + String(repeating: "s", count: 32)
        try secret.write(toFile: source, atomically: true, encoding: .utf8)
        let revision = FileSnapshot(
            data: Data(secret.utf8),
            modifiedDate: nil
        ).revision

        await #expect(throws: SensitiveContentPolicy.Violation.self) {
            _ = try await runtime.paths.move(.file(
                sourcePath: relative,
                destinationPath: "notes/completed/overview.md",
                format: .markdown,
                expectedRevision: revision
            ))
        }
        await #expect(throws: FileRoutingError.self) {
            _ = try await runtime.paths.move(.file(
                sourcePath: relative,
                destinationPath: "notes/completed/overview.json",
                format: .markdown,
                expectedRevision: revision
            ))
        }
        await #expect(throws: FileRoutingError.self) {
            _ = try await runtime.paths.move(.file(
                sourcePath: relative,
                destinationPath: "references/overview.md",
                format: .markdown,
                expectedRevision: revision
            ))
        }
        #expect(FileManager.default.fileExists(atPath: source))
        #expect(!FileManager.default.fileExists(
            atPath: root + "/notes/completed/overview.md"
        ))
    }

    @Test
    func `File moves refuse destination clobber and symbolic-link sources`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: root + "/notes/completed",
            withIntermediateDirectories: true
        )
        try "occupied".write(
            toFile: root + "/notes/completed/overview.md",
            atomically: true,
            encoding: .utf8
        )
        let runtime = try await makeRecoveredRuntime(vaultPath: root)
        let sourcePath = "notes/in-progress/ticket-123/overview.md"
        let bytes = try Data(contentsOf: URL(fileURLWithPath: root + "/" + sourcePath))
        let revision = FileSnapshot(data: bytes, modifiedDate: nil).revision

        await #expect(throws: PathMoveError.self) {
            _ = try await runtime.paths.move(.file(
                sourcePath: sourcePath,
                destinationPath: "notes/completed/overview.md",
                format: .markdown,
                expectedRevision: revision
            ))
        }

        let linkedPath = root + "/notes/in-progress/linked.md"
        try FileManager.default.createSymbolicLink(
            atPath: linkedPath,
            withDestinationPath: root + "/" + sourcePath
        )
        await #expect(throws: PathValidationError.self) {
            _ = try await runtime.paths.move(.file(
                sourcePath: "notes/in-progress/linked.md",
                destinationPath: "notes/completed/linked.md",
                format: .markdown,
                expectedRevision: revision
            ))
        }
        #expect(try String(
            contentsOfFile: root + "/notes/completed/overview.md",
            encoding: .utf8
        ) == "occupied")
        #expect(FileManager.default.fileExists(atPath: root + "/" + sourcePath))
    }

    @Test
    func `A source substitution immediately before rename is rejected`() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let relative = "notes/in-progress/ticket-123/overview.md"
        let source = try WritableFileTarget.resolve(
            path: relative,
            format: .markdown,
            vaultPath: root
        )
        let destination = try WritableFileTarget.resolve(
            path: "notes/completed/overview.md",
            format: .markdown,
            vaultPath: root
        )
        let original = try Data(contentsOf: source.url)
        let expected = FileSnapshot(data: original, modifiedDate: nil).revision
        let displaced = root + "/notes/in-progress/displaced.md"
        let tree = PathTreeStore(vaultPath: root) {
            try FileManager.default.moveItem(
                atPath: source.url.path,
                toPath: displaced
            )
            try "replacement".write(
                toFile: source.url.path,
                atomically: true,
                encoding: .utf8
            )
        }

        #expect(throws: PathMoveError.self) {
            _ = try tree.moveFile(
                source: source,
                destination: destination,
                expectedRevision: expected
            )
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: displaced)) == original)
        #expect(try String(contentsOf: source.url, encoding: .utf8) == "replacement")
        #expect(!FileManager.default.fileExists(atPath: destination.url.path))
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

        _ = try await runtime.paths.move(MovePathRequest.directory(

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
            _ = try await runtime.paths.move(MovePathRequest.directory(

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
            _ = try await runtime.paths.move(MovePathRequest.directory(

                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/ticket-123"
            ))
        }
        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.paths.move(MovePathRequest.directory(

                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/completed/Ticket.app/ticket-123"
            ))
        }
        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.paths.move(MovePathRequest.directory(

                sourcePath: "notes/in-progress/ticket-123",
                destinationPath: "notes/in-progress/ticket-123/inside"
            ))
        }
        await #expect(throws: FileRoutingError.self) {
            _ = try await runtime.paths.move(MovePathRequest.directory(

                sourcePath: "references/books",
                destinationPath: "notes/completed/books"
            ))
        }
        await #expect(throws: DirectoryMoveError.self) {
            _ = try await runtime.paths.move(MovePathRequest.directory(

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
            _ = try await runtime.paths.move(MovePathRequest.directory(

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
            _ = try await runtime.paths.move(MovePathRequest.directory(

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
            _ = try await runtime.paths.move(MovePathRequest.directory(

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
            _ = try await runtime.paths.move(MovePathRequest.directory(

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

        _ = try await runtime.paths.move(MovePathRequest.directory(

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

        _ = try await runtime.paths.move(MovePathRequest.directory(

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
            _ = try await runtime.paths.move(MovePathRequest.directory(

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
            _ = try await runtime.paths.move(MovePathRequest.directory(

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
            _ = try await runtime.paths.move(MovePathRequest.directory(

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
        let tree = PathTreeStore(vaultPath: root) {
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
            _ = try tree.moveDirectory(
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
        let tree = PathTreeStore(vaultPath: root)
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
        let wrong = PathTreeStore.Identity(
            device: identity.device,
            inode: identity.inode,
            birthSeconds: identity.birthSeconds,
            birthNanoseconds: identity.birthNanoseconds + 1
        )
        #expect(throws: DirectoryMoveError.self) {
            _ = try tree.moveDirectory(
                source: source,
                destination: destination,
                expectedIdentity: wrong
            )
        }
        #expect(FileManager.default.fileExists(atPath: source.url.path))
    }

    private enum TestFailure: Error { case git }
}
