import Darwin
import Foundation
import Testing
@testable import second_brain_mcp

/// Integration coverage for the intentionally small vault-snapshot contract.
@Suite
struct `GitRepository snapshots` {
    /// `/usr/bin/git` is an xcode-select shim, not the product subprocess that
    /// was code-signed as Apple Git. Resolution must return and validate the
    /// canonical executable before any vault bytes reach a child process.
    @Test
    func `product resolves validated Apple Git instead of the system shim`() throws {
        let executable = try AppleGitExecutable.resolve()

        #expect(executable.path != "/usr/bin/git")
        #expect(AppleGitExecutable.isTrusted(executable))
        #expect(
            !AppleGitExecutable.isTrusted(
                URL(fileURLWithPath: "/usr/bin/git")
            )
        )
    }

    @Test
    func `trusted Git resolution retries after availability changes`() throws {
        do {
            _ = try AppleGitExecutable.resolve(locator: { nil })
            Issue.record("Expected unavailable trusted Git")
        } catch let error as VaultVersioningError {
            guard case .trustedGitUnavailable = error else {
                Issue.record("Expected unavailable trusted Git, got \(error)")
                return
            }
        }
        let expected = try AppleGitExecutable.resolve()
        let retried = try AppleGitExecutable.resolve(locator: { expected })

        #expect(retried == expected)
    }

    @Test
    func `snapshot retry resolves Git again after selected executable cannot launch`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let trustedGit = try AppleGitExecutable.resolve()
        let transientGit = vault.cleanupRoot.appendingPathComponent("missing-git")
        let resolver = GitExecutableResolverProbe(
            initial: transientGit,
            fallback: trustedGit
        )
        let repository = try GitRepository(
            vaultURL: vault.root,
            dataDirectory: vault.dataDirectory,
            gitExecutableResolver: { try resolver.resolve() }
        )
        let note = vault.notes.appendingPathComponent("memory.md")
        try Data("second".utf8).write(to: note, options: .atomic)

        do {
            try await repository.recordSnapshot()
            Issue.record("Expected the selected executable launch to fail")
        } catch let error as VaultVersioningError {
            guard case .trustedGitUnavailable = error else {
                Issue.record("Expected trusted Git to be re-resolved, got \(error)")
                return
            }
        }
        try await repository.recordSnapshot()

        #expect(resolver.calls == 2)
        #expect(
            try runSnapshotGit(
                ["show", "\(try latestSnapshotReference(in: vault)):notes/memory.md"],
                in: vault
            ) == "second"
        )
    }

    @Test
    func `later snapshot revalidates and replaces a cached Git selection`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let trustedGit = try AppleGitExecutable.resolve()
        let resolver = GitExecutableResolverProbe(
            initial: trustedGit,
            fallback: trustedGit
        )
        let validator = GitExecutableValidatorProbe()
        let repository = try GitRepository(
            vaultURL: vault.root,
            dataDirectory: vault.dataDirectory,
            gitExecutableResolver: { try resolver.resolve() },
            gitExecutableValidator: { validator.validate($0) }
        )
        try Data("note".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )

        try await repository.recordSnapshot()
        try await repository.recordSnapshot()

        #expect(validator.calls == 1)
        #expect(resolver.calls == 2)
    }

    @Test
    func `retry revalidates Git after an unsuccessful version probe`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let trustedGit = try AppleGitExecutable.resolve()
        let failingGit = vault.cleanupRoot.appendingPathComponent("failing-git")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: failingGit, options: .atomic)
        #expect(Darwin.chmod(failingGit.path, 0o700) == 0)
        let resolver = GitExecutableResolverProbe(
            initial: failingGit,
            fallback: trustedGit
        )
        let validator = GitExecutableValidatorProbe()
        let repository = try GitRepository(
            vaultURL: vault.root,
            dataDirectory: vault.dataDirectory,
            gitExecutableResolver: { try resolver.resolve() },
            gitExecutableValidator: { validator.validate($0) }
        )
        try Data("recoverable".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )

        await #expect(throws: VaultVersioningError.self) {
            try await repository.recordSnapshot()
        }
        try await repository.recordSnapshot()

        #expect(validator.calls == 1)
        #expect(resolver.calls == 2)
        #expect(
            try runSnapshotGit(
                ["show", "\(try latestSnapshotReference(in: vault)):notes/memory.md"],
                in: vault
            ) == "recoverable"
        )
    }

    /// Automated recovery must never contend with, rewrite, or unlock the
    /// staging index owned by an interactive Git client.
    @Test
    func `snapshot bypasses a foreign index lock and leaves user Git state untouched`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let note = vault.notes.appendingPathComponent("memory.md")
        try Data("baseline".utf8).write(to: note, options: .atomic)
        _ = try runGit(["init"], in: vault.root)
        _ = try runGit(["add", "--", "notes/memory.md"], in: vault.root)
        _ = try runGit([
            "-c", "user.name=Test",
            "-c", "user.email=test@example.invalid",
            "commit", "--no-gpg-sign", "-m", "User baseline",
        ], in: vault.root)

        let references = vault.root.appendingPathComponent("references")
        try FileManager.default.createDirectory(
            at: references,
            withIntermediateDirectories: true
        )
        try Data("user staging".utf8).write(
            to: references.appendingPathComponent("staged.txt"),
            options: .atomic
        )
        _ = try runGit(["add", "--", "references/staged.txt"], in: vault.root)

        let indexURL = try gitPath("index", in: vault.root)
        let indexBefore = try Data(contentsOf: indexURL)
        let headBefore = try runGit(["rev-parse", "HEAD"], in: vault.root)
        let lockURL = indexURL.deletingLastPathComponent()
            .appendingPathComponent("index.lock")
        let lockSentinel = Data("foreign Git owns this lock".utf8)
        try lockSentinel.write(to: lockURL, options: .withoutOverwriting)
        try Data("snapshot bytes".utf8).write(to: note, options: .atomic)

        try await makeRepository(for: vault).recordSnapshot()

        #expect(try Data(contentsOf: lockURL) == lockSentinel)
        #expect(try Data(contentsOf: indexURL) == indexBefore)
        #expect(try runGit(["rev-parse", "HEAD"], in: vault.root) == headBefore)
        #expect(
            try runSnapshotGit(
                ["show", "\(try latestSnapshotReference(in: vault)):notes/memory.md"],
                in: vault
            ) == "snapshot bytes"
        )
    }

    /// The strongest index-isolation case is a user staging one version of the
    /// same note while the working tree contains a later version to snapshot.
    @Test
    func `snapshot preserves a separately staged version of the same note`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let note = vault.notes.appendingPathComponent("memory.md")
        try Data("baseline".utf8).write(to: note, options: .atomic)
        _ = try runGit(["init"], in: vault.root)
        _ = try runGit(["add", "--", "notes/memory.md"], in: vault.root)
        _ = try runGit([
            "-c", "user.name=Test",
            "-c", "user.email=test@example.invalid",
            "commit", "--no-gpg-sign", "-m", "User baseline",
        ], in: vault.root)

        try Data("user staged".utf8).write(to: note, options: .atomic)
        _ = try runGit(["add", "--", "notes/memory.md"], in: vault.root)
        let indexURL = try gitPath("index", in: vault.root)
        let indexBefore = try Data(contentsOf: indexURL)
        let headBefore = try runGit(["rev-parse", "HEAD"], in: vault.root)
        try Data("working snapshot".utf8).write(to: note, options: .atomic)

        try await makeRepository(for: vault).recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)

        #expect(try Data(contentsOf: indexURL) == indexBefore)
        #expect(try runGit(["rev-parse", "HEAD"], in: vault.root) == headBefore)
        #expect(try runGit(["show", ":notes/memory.md"], in: vault.root) == "user staged")
        #expect(
            try runSnapshotGit(
                ["show", "\(snapshotReference):notes/memory.md"],
                in: vault
            ) == "working snapshot"
        )
    }

    /// Verifies that a brand-new vault with no `notes/` path remains a no-op
    /// rather than manufacturing an empty recovery commit.
    @Test
    func `an empty vault is already a valid snapshot`() async throws {
        let vault = try makeVault(createNotesDirectory: false)
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)

        try await repository.recordSnapshot()
        try await repository.recordSnapshot()

        #expect(
            !FileManager.default.fileExists(
                atPath: vault.root
                    .appendingPathComponent(".git")
                    .path(percentEncoded: false)
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: vault.dataDirectory.snapshotRepositoryURL.path
            )
        )
        #expect(try latestSnapshotReference(in: vault).isEmpty)
    }

    /// Verifies that snapshots are restricted to notes and that a clean request
    /// does not manufacture an additional commit.
    @Test
    func `snapshots notes and treats an unchanged vault as success`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)

        try Data("remember this".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )
        try Data("not a note".utf8).write(
            to: vault.root.appendingPathComponent("outside.txt"),
            options: .atomic
        )

        try await repository.recordSnapshot()
        let initialReference = try latestSnapshotReference(in: vault)

        try await repository.recordSnapshot()

        #expect(
            try runSnapshotGit(
                ["rev-list", "--count", initialReference],
                in: vault
            ) == "1"
        )
        #expect(
            try latestSnapshotReference(in: vault) == initialReference
        )
        #expect(
            try runSnapshotGit(
                ["ls-tree", "-r", "--name-only", initialReference],
                in: vault
            ) == "notes/memory.md"
        )
    }

    /// Interactive mutations must not rescan or absorb unrelated vault changes.
    /// Startup recovery remains responsible for whole-vault reconciliation.
    @Test
    func `scoped snapshot records only the paths changed by the mutation`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let target = vault.notes.appendingPathComponent("target.md")
        let unrelated = vault.notes.appendingPathComponent("unrelated.md")
        try Data("target before".utf8).write(to: target, options: .atomic)
        try Data("unrelated before".utf8).write(to: unrelated, options: .atomic)
        try await repository.recordSnapshot()

        try Data("target after".utf8).write(to: target, options: .atomic)
        try Data("unrelated after".utf8).write(to: unrelated, options: .atomic)
        try await repository.recordSnapshot(changing: ["notes/target.md"])
        let snapshotReference = try latestSnapshotReference(in: vault)

        #expect(
            try runSnapshotGit(
                ["show", "\(snapshotReference):notes/target.md"],
                in: vault
            ) == "target after"
        )
        #expect(
            try runSnapshotGit(
                ["show", "\(snapshotReference):notes/unrelated.md"],
                in: vault
            ) == "unrelated before"
        )
    }

    @Test
    func `first scoped snapshot does not scan unrelated notes`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        try Data("target".utf8).write(
            to: vault.notes.appendingPathComponent("target.md"),
            options: .atomic
        )
        try Data("unrelated".utf8).write(
            to: vault.notes.appendingPathComponent("unrelated.md"),
            options: .atomic
        )

        try await repository.recordSnapshot(changing: ["notes/target.md"])
        let snapshotReference = try latestSnapshotReference(in: vault)

        #expect(
            try runSnapshotGit(
                ["ls-tree", "-r", "--name-only", snapshotReference, "--", "notes"],
                in: vault
            ) == "notes/target.md"
        )
    }

    @Test
    func `scoped snapshot rejects a special target whose name resembles Git diagnostics`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let path = "notes/did not match any files.pipe"
        let pipe = vault.root.appendingPathComponent(path)

        #expect(Darwin.mkfifo(pipe.path, 0o600) == 0)

        await #expect(throws: VaultVersioningError.self) {
            try await repository.prepareForMutation(changing: [path])
        }
    }

    @Test
    func `scoped snapshot does not mistake caller-influenced Git diagnostics for absence`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let path = "notes/failure did not match any files.md"
        let note = vault.root.appendingPathComponent(path)
        try Data("unreadable".utf8).write(to: note, options: .atomic)
        #expect(Darwin.chmod(note.path, 0o000) == 0)
        defer { _ = Darwin.chmod(note.path, 0o600) }

        await #expect(throws: VaultVersioningError.self) {
            try await repository.prepareForMutation(changing: [path])
        }
    }

    @Test
    func `scoped deletion and file move update only their declared paths`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let source = vault.notes.appendingPathComponent("source.md")
        let destination = vault.notes.appendingPathComponent("destination.md")
        let deleted = vault.notes.appendingPathComponent("deleted.md")
        let unrelated = vault.notes.appendingPathComponent("unrelated.md")
        try Data("move bytes\r\n".utf8).write(to: source, options: .atomic)
        try Data("delete bytes".utf8).write(to: deleted, options: .atomic)
        try Data("unrelated before".utf8).write(to: unrelated, options: .atomic)
        try await repository.recordSnapshot()

        try FileManager.default.moveItem(at: source, to: destination)
        try FileManager.default.removeItem(at: deleted)
        try Data("unrelated after".utf8).write(to: unrelated, options: .atomic)
        try await repository.recordSnapshot(
            changing: ["notes/source.md", "notes/destination.md"]
        )
        try await repository.recordSnapshot(changing: ["notes/deleted.md"])
        let snapshotReference = try latestSnapshotReference(in: vault)

        #expect(
            try runSnapshotGit(
                ["ls-tree", "-r", "--name-only", snapshotReference, "--", "notes"],
                in: vault
            ).split(separator: "\n").map(String.init)
                == ["notes/destination.md", "notes/unrelated.md"]
        )
        #expect(
            try runSnapshotGitBytes(
                ["show", "\(snapshotReference):notes/destination.md"],
                in: vault
            ) == Data("move bytes\r\n".utf8)
        )
        #expect(
            try runSnapshotGit(
                ["show", "\(snapshotReference):notes/unrelated.md"],
                in: vault
            ) == "unrelated before"
        )
    }

    @Test
    func `unrelated embedded repository blocks recovery but not a scoped mutation`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let target = vault.notes.appendingPathComponent("target.md")
        try Data("before".utf8).write(to: target, options: .atomic)
        try await repository.recordSnapshot()

        let unrelatedGit = vault.notes
            .appendingPathComponent("external", isDirectory: true)
            .appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unrelatedGit,
            withIntermediateDirectories: true
        )
        try Data("after".utf8).write(to: target, options: .atomic)

        try await repository.recordSnapshot(changing: ["notes/target.md"])
        #expect(
            try runSnapshotGit(
                ["show", "\(try latestSnapshotReference(in: vault)):notes/target.md"],
                in: vault
            ) == "after"
        )
        await #expect(throws: VaultVersioningError.self) {
            try await repository.recordSnapshot()
        }
    }

    @Test
    func `scoped snapshot rejects paths outside validated notes files`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)

        for paths in [
            ["references/no.md"],
            ["notes/../outside.md"],
            ["notes/.hidden/file.md"],
            ["notes/.git/config"],
            ["notes/a.md", "notes/b.md", "notes/c.md"],
        ] {
            await #expect(throws: VaultVersioningError.self) {
                try await repository.recordSnapshot(changing: paths)
            }
        }
    }

    @Test
    func `live retry retightens an owned private repository after repair`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let note = vault.notes.appendingPathComponent("memory.md")
        try Data("before repair".utf8).write(to: note, options: .atomic)
        try await repository.recordSnapshot()

        let privateRepository = vault.dataDirectory.snapshotRepositoryURL
        #expect(Darwin.chmod(privateRepository.path, 0o755) == 0)
        try Data("after repair".utf8).write(to: note, options: .atomic)

        try await repository.recordSnapshot()

        var metadata = stat()
        #expect(Darwin.lstat(privateRepository.path, &metadata) == 0)
        #expect(metadata.st_mode & 0o777 == 0o700)
        #expect(
            try runSnapshotGit(
                ["show", "\(try latestSnapshotReference(in: vault)):notes/memory.md"],
                in: vault
            ) == "after repair"
        )
    }

    @Test
    func `live retry refuses a replaced private data root before permission repair`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let note = vault.notes.appendingPathComponent("memory.md")
        try Data("baseline".utf8).write(to: note, options: .atomic)
        try await repository.recordSnapshot()

        let installedRoot = vault.dataDirectory.rootURL
        let preservedRoot = vault.cleanupRoot.appendingPathComponent("preserved-support")
        let outsideRoot = vault.cleanupRoot.appendingPathComponent("outside-support")
        try FileManager.default.moveItem(at: installedRoot, to: preservedRoot)
        try FileManager.default.copyItem(at: preservedRoot, to: outsideRoot)
        let outsideRepository = outsideRoot.appendingPathComponent("git-snapshots-v1.git")
        #expect(Darwin.chmod(outsideRepository.path, 0o755) == 0)
        try FileManager.default.createSymbolicLink(
            at: installedRoot,
            withDestinationURL: outsideRoot
        )
        try Data("must not escape".utf8).write(to: note, options: .atomic)

        do {
            try await repository.recordSnapshot()
            Issue.record("Expected replacement of the private data root to fail closed")
        } catch let error as VaultVersioningError {
            guard case .invalidPrivateRepository = error else {
                Issue.record("Expected invalid private repository, got \(error)")
                return
            }
        }

        var metadata = stat()
        #expect(Darwin.lstat(outsideRepository.path, &metadata) == 0)
        #expect(metadata.st_mode & 0o777 == 0o755)
        #expect(
            try runGit(
                ["show", "\(try latestSnapshotReference(in: vault)):notes/memory.md"],
                in: vault.root,
                gitDirectory: outsideRepository
            ) == "baseline"
        )
    }

    @Test
    func `private root replacement cannot create the snapshot lock outside its boundary`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let installedRoot = vault.dataDirectory.rootURL
        let preservedRoot = vault.cleanupRoot.appendingPathComponent("preserved-lock-root")
        let outsideRoot = vault.cleanupRoot.appendingPathComponent("outside-lock-root")
        try FileManager.default.copyItem(at: installedRoot, to: outsideRoot)
        let outsideLock = outsideRoot.appendingPathComponent("locks/git-snapshot.lock")
        let repository = try GitRepository(
            vaultURL: vault.root,
            dataDirectory: vault.dataDirectory,
            preSnapshotLockObserver: {
                try FileManager.default.moveItem(at: installedRoot, to: preservedRoot)
                try FileManager.default.createSymbolicLink(
                    at: installedRoot,
                    withDestinationURL: outsideRoot
                )
            }
        )
        try Data("must stay inside".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )

        do {
            try await repository.recordSnapshot()
            Issue.record("Expected private root replacement to fail closed")
        } catch let error as VaultVersioningError {
            guard case .invalidPrivateRepository = error else {
                Issue.record("Expected invalid private repository, got \(error)")
                return
            }
        }

        #expect(!FileManager.default.fileExists(atPath: outsideLock.path))
    }

    @Test
    func `private root replacement during staging cannot publish an outside snapshot`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let note = vault.notes.appendingPathComponent("memory.md")
        try Data("baseline".utf8).write(to: note, options: .atomic)
        try await makeRepository(for: vault).recordSnapshot()
        let baselineReference = try latestSnapshotReference(in: vault)

        let installedRoot = vault.dataDirectory.rootURL
        let preservedRoot = vault.cleanupRoot.appendingPathComponent("preserved-stage-root")
        let outsideRoot = vault.cleanupRoot.appendingPathComponent("outside-stage-root")
        let outsideRepository = outsideRoot.appendingPathComponent("git-snapshots-v1.git")
        let repository = try GitRepository(
            vaultURL: vault.root,
            dataDirectory: vault.dataDirectory,
            postStageObserver: {
                try FileManager.default.copyItem(at: installedRoot, to: outsideRoot)
                let copiedWorkspaceRoot = outsideRoot.appendingPathComponent(
                    "git-snapshot-workspaces-v1"
                )
                let copiedWorkspaces = try FileManager.default.contentsOfDirectory(
                    at: copiedWorkspaceRoot,
                    includingPropertiesForKeys: nil
                )
                guard let copiedWorkspace = copiedWorkspaces.first else {
                    throw CocoaError(.fileNoSuchFile)
                }
                try Data("outside sentinel".utf8).write(
                    to: copiedWorkspace.appendingPathComponent("outside-sentinel"),
                    options: .atomic
                )
                try FileManager.default.moveItem(at: installedRoot, to: preservedRoot)
                try FileManager.default.createSymbolicLink(
                    at: installedRoot,
                    withDestinationURL: outsideRoot
                )
            }
        )
        try Data("must not escape".utf8).write(to: note, options: .atomic)

        do {
            try await repository.recordSnapshot()
            Issue.record("Expected private root replacement to fail closed")
        } catch let error as VaultVersioningError {
            guard case .invalidPrivateRepository = error else {
                Issue.record("Expected invalid private repository, got \(error)")
                return
            }
        }

        let outsideReference = try runGit(
            ["for-each-ref", "--format=%(refname)", "refs/second-brain-mcp/snapshots"],
            in: vault.root,
            gitDirectory: outsideRepository
        )
        #expect(outsideReference == baselineReference)
        #expect(
            try runGit(
                ["show", "\(outsideReference):notes/memory.md"],
                in: vault.root,
                gitDirectory: outsideRepository
            ) == "baseline"
        )
        let outsideWorkspaceRoot = outsideRoot.appendingPathComponent(
            "git-snapshot-workspaces-v1"
        )
        let outsideSentinelSurvives = FileManager.default.enumerator(
            at: outsideWorkspaceRoot,
            includingPropertiesForKeys: nil
        )?.compactMap { ($0 as? URL)?.lastPathComponent }
            .contains("outside-sentinel") ?? false
        #expect(outsideSentinelSurvives)
    }

    /// Proves a snapshot commits only `notes/`, even when another Git client has
    /// already staged reference content in the repository's real index.
    @Test
    func `a snapshot leaves staged reference content out of history`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let firstNote = vault.notes.appendingPathComponent("first.md")

        try Data("first version".utf8).write(to: firstNote, options: .atomic)
        try await repository.recordSnapshot()

        let references = vault.root.appendingPathComponent("references")
        try FileManager.default.createDirectory(
            at: references,
            withIntermediateDirectories: true
        )
        try Data("large reference placeholder".utf8).write(
            to: references.appendingPathComponent("book.pdf"),
            options: .atomic
        )
        _ = try runGit(["init"], in: vault.root)
        _ = try runGit(["add", "--", "references/book.pdf"], in: vault.root)

        try Data("second version".utf8).write(to: firstNote, options: .atomic)
        try await repository.recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)

        #expect(
            try runSnapshotGit(
                ["show", "--pretty=", "--name-only", snapshotReference],
                in: vault
            ) == "notes/first.md"
        )
        #expect(
            try runGit(
                ["diff", "--cached", "--name-only", "--", "references"],
                in: vault.root
            ) == "references/book.pdf"
        )
        #expect(
            try runSnapshotGit(
                [
                    "ls-tree", "-r", "--name-only", snapshotReference,
                    "--", "references",
                ],
                in: vault
            ).isEmpty
        )
    }

    /// Existing user history can contain editor state from before the vault was
    /// restricted to `notes/`. The first product snapshot must not inherit it.
    @Test
    func `first snapshot excludes Obsidian state inherited from user HEAD`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let note = vault.notes.appendingPathComponent("memory.md")
        let obsidian = vault.root.appendingPathComponent(".obsidian")
        try FileManager.default.createDirectory(
            at: obsidian,
            withIntermediateDirectories: true
        )
        try Data("baseline".utf8).write(to: note, options: .atomic)
        try Data("editor state".utf8).write(
            to: obsidian.appendingPathComponent("workspace.json"),
            options: .atomic
        )
        _ = try runGit(["init"], in: vault.root)
        _ = try runGit(["add", "--all"], in: vault.root)
        _ = try runGit([
            "-c", "user.name=Test",
            "-c", "user.email=test@example.invalid",
            "commit", "--no-gpg-sign", "-m", "User baseline",
        ], in: vault.root)

        try Data("snapshot".utf8).write(to: note, options: .atomic)
        try await makeRepository(for: vault).recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)
        let snapshotParents = try runSnapshotGit(
            ["rev-list", "--parents", "-n", "1", snapshotReference],
            in: vault
        ).split(separator: " ")
        let snapshotObjects = try runSnapshotGit(
            ["rev-list", "--objects", snapshotReference],
            in: vault
        )

        #expect(
            try runSnapshotGit(
                ["ls-tree", "-r", "--name-only", snapshotReference],
                in: vault
            ) == "notes/memory.md"
        )
        #expect(snapshotParents.count == 1)
        #expect(!snapshotObjects.contains(".obsidian"))
    }

    /// Product snapshots own `notes/` independently of Git configuration. A
    /// user's ignore policy must not make a successful mutation unrecoverable.
    @Test(arguments: ["worktree", "repository", "configured"])
    func `snapshots notes despite every Git ignore source`(_ ignoreSource: String) async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        _ = try runGit(["init"], in: vault.root)

        switch ignoreSource {
        case "worktree":
            try Data("/notes/\n".utf8).write(
                to: vault.root.appendingPathComponent(".gitignore"),
                options: .atomic
            )
        case "repository":
            try Data("/notes/\n".utf8).write(
                to: try gitPath("info/exclude", in: vault.root),
                options: .atomic
            )
        case "configured":
            let excludes = vault.root.appendingPathComponent("third-party-excludes")
            try Data("/notes/\n".utf8).write(to: excludes, options: .atomic)
            _ = try runGit(
                ["config", "core.excludesFile", excludes.path],
                in: vault.root
            )
        default:
            Issue.record("Unknown ignore source fixture")
        }

        try Data("must be recoverable".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )

        try await makeRepository(for: vault).recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)

        #expect(
            try runSnapshotGit(
                ["show", "\(snapshotReference):notes/memory.md"],
                in: vault
            ) == "must be recoverable"
        )
    }

    @Test
    func `nested ignore rules cannot hide a note or its later deletion`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let note = vault.notes.appendingPathComponent("ignored.md")
        try Data("*.md\n".utf8).write(
            to: vault.notes.appendingPathComponent(".gitignore"),
            options: .atomic
        )
        try Data("recoverable".utf8).write(to: note, options: .atomic)

        try await repository.recordSnapshot()
        let firstReference = try latestSnapshotReference(in: vault)
        #expect(
            try runSnapshotGit(
                ["show", "\(firstReference):notes/ignored.md"],
                in: vault
            ) == "recoverable"
        )

        try FileManager.default.removeItem(at: note)
        try await repository.recordSnapshot()
        let deletionReference = try latestSnapshotReference(in: vault)

        #expect(
            try runSnapshotGit(
                ["ls-tree", "-r", "--name-only", deletionReference, "--", "notes/ignored.md"],
                in: vault
            ).isEmpty
        )
    }

    /// Linked worktrees store the real index and its lock outside the checkout.
    /// Sparse policy is also user-owned and cannot exclude an explicit note.
    @Test
    func `linked sparse worktree bypasses its real index lock and owns a separate ref`() async throws {
        let primary = try makeVault(createNotesDirectory: false)
        let linkedRoot = primary.root.deletingLastPathComponent().appendingPathComponent(
            "GitRepositoryLinkedTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { primary.remove() }
        let kept = primary.root.appendingPathComponent("kept")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("anchor".utf8).write(
            to: kept.appendingPathComponent("anchor.txt"),
            options: .atomic
        )
        _ = try runGit(["init"], in: primary.root)
        _ = try runGit(["add", "--all"], in: primary.root)
        _ = try runGit([
            "-c", "user.name=Test",
            "-c", "user.email=test@example.invalid",
            "commit", "--no-gpg-sign", "-m", "User baseline",
        ], in: primary.root)
        _ = try runGit(
            ["worktree", "add", "--detach", linkedRoot.path],
            in: primary.root
        )
        _ = try runGit(["sparse-checkout", "set", "kept"], in: linkedRoot)

        let linkedNotes = linkedRoot.appendingPathComponent("notes")
        try FileManager.default.createDirectory(
            at: linkedNotes,
            withIntermediateDirectories: true
        )
        try Data("linked snapshot".utf8).write(
            to: linkedNotes.appendingPathComponent("memory.md"),
            options: .atomic
        )
        let linkedIndex = try gitPath("index", in: linkedRoot)
        let indexBefore = try Data(contentsOf: linkedIndex)
        let headBefore = try runGit(["rev-parse", "HEAD"], in: linkedRoot)
        let lockURL = try gitPath("index.lock", in: linkedRoot)
        let lockSentinel = Data("linked user lock".utf8)
        try lockSentinel.write(to: lockURL, options: .withoutOverwriting)
        let linkedVault = TestVault(
            cleanupRoot: primary.cleanupRoot,
            root: linkedRoot,
            notes: linkedNotes,
            dataDirectory: try VaultDataDirectory.prepare(
                vaultPath: linkedRoot.path,
                supportRoot: primary.cleanupRoot.appendingPathComponent(
                    "linked-support",
                    isDirectory: true
                )
            )
        )

        try await makeRepository(for: linkedVault).recordSnapshot()
        let linkedReference = try latestSnapshotReference(in: linkedVault)
        _ = try runGit(["reflog", "expire", "--expire=now", "--all"], in: primary.root)
        _ = try runGit(["gc", "--prune=now"], in: primary.root)

        #expect(!linkedReference.isEmpty)
        #expect(try latestSnapshotReference(in: primary).isEmpty)
        #expect(try Data(contentsOf: lockURL) == lockSentinel)
        #expect(try Data(contentsOf: linkedIndex) == indexBefore)
        #expect(try runGit(["rev-parse", "HEAD"], in: linkedRoot) == headBefore)
        #expect(
            try runSnapshotGit(
                ["show", "\(linkedReference):notes/memory.md"],
                in: linkedVault
            ) == "linked snapshot"
        )
    }

    /// Ref leaves are unique, so a stale lock beside the previous product ref
    /// can prevent only pruning and never block the next durable snapshot.
    @Test
    func `stale previous product ref lock cannot block a later snapshot`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let note = vault.notes.appendingPathComponent("memory.md")
        try Data("first".utf8).write(to: note, options: .atomic)
        try await repository.recordSnapshot()
        let firstReference = try latestSnapshotReference(in: vault)
        let staleLock = try snapshotGitPath("\(firstReference).lock", in: vault)
        let sentinel = Data("stale product ref lock".utf8)
        try sentinel.write(to: staleLock, options: .withoutOverwriting)
        for (key, value) in [
            ("core.filesRefLockTimeout", "-1"),
            ("core.packedRefsTimeout", "-1"),
            ("reftable.lockTimeout", "-1"),
        ] {
            _ = try runSnapshotGit(["config", key, value], in: vault)
        }

        try Data("second".utf8).write(to: note, options: .atomic)
        let clock = ContinuousClock()
        let started = clock.now
        try await repository.recordSnapshot()
        let secondReference = try latestSnapshotReference(in: vault)

        #expect(secondReference != firstReference)
        #expect(started.duration(to: clock.now) < .seconds(2))
        #expect(try Data(contentsOf: staleLock) == sentinel)
        #expect(
            try runSnapshotGit(
                ["show", "\(secondReference):notes/memory.md"],
                in: vault
            ) == "second"
        )

        try Data("third".utf8).write(to: note, options: .atomic)
        try await repository.recordSnapshot()
        let thirdReference = try latestSnapshotReference(in: vault)
        #expect(thirdReference != secondReference)
        #expect(try Data(contentsOf: staleLock) == sentinel)
        #expect(
            try runSnapshotGit(
                ["show", "\(thirdReference):notes/memory.md"],
                in: vault
            ) == "third"
        )
    }

    /// Initialization is not repeated after the private repository is valid,
    /// so an abandoned init/config lock cannot wedge later snapshot retries.
    @Test
    func `stale product config lock cannot block an existing repository`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let note = vault.notes.appendingPathComponent("memory.md")
        try Data("first".utf8).write(to: note, options: .atomic)
        try await repository.recordSnapshot()

        let configLock = vault.dataDirectory.snapshotRepositoryURL
            .appendingPathComponent("config.lock")
        let sentinel = Data("abandoned init lock".utf8)
        try sentinel.write(to: configLock, options: .withoutOverwriting)
        try Data("second".utf8).write(to: note, options: .atomic)

        try await repository.recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)

        #expect(try Data(contentsOf: configLock) == sentinel)
        #expect(
            try runSnapshotGit(
                ["show", "\(snapshotReference):notes/memory.md"],
                in: vault
            ) == "second"
        )
    }

    /// Corrupted product metadata must fail closed before an internal symlink
    /// can redirect product writes into the user's repository.
    @Test
    func `product repository info symlink cannot rewrite user Git metadata`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let note = vault.notes.appendingPathComponent("memory.md")
        try Data("first".utf8).write(to: note, options: .atomic)
        try await repository.recordSnapshot()
        _ = try runGit(["init"], in: vault.root)
        let userInfo = try gitPath("info", in: vault.root)
        let userAttributes = userInfo.appendingPathComponent("attributes")
        let sentinel = Data("user-owned attributes\n".utf8)
        try sentinel.write(to: userAttributes, options: .atomic)

        let productInfo = vault.dataDirectory.snapshotRepositoryURL
            .appendingPathComponent("info")
        try FileManager.default.removeItem(at: productInfo)
        try FileManager.default.createSymbolicLink(
            at: productInfo,
            withDestinationURL: userInfo
        )
        try Data("second".utf8).write(to: note, options: .atomic)

        do {
            try await repository.recordSnapshot()
            Issue.record("Expected invalid private repository failure")
        } catch let error as VaultVersioningError {
            guard case .invalidPrivateRepository = error else {
                Issue.record("Expected invalid private repository, got \(error)")
                return
            }
        }
        #expect(try Data(contentsOf: userAttributes) == sentinel)
    }

    /// Crash leftovers are cleanup candidates, never an artificial capacity
    /// lock that can disable every future snapshot while disk space remains.
    @Test
    func `many fresh private index leftovers cannot wedge recovery`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let workspaceRoot = vault.dataDirectory.snapshotWorkspaceDirectoryURL
        for _ in 0..<300 {
            try FileManager.default.createDirectory(
                at: workspaceRoot.appendingPathComponent(
                    "SecondBrainMCP-snapshot-index-\(UUID().uuidString)",
                    isDirectory: true
                ),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try Data("snapshot".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )
        let repository = try makeRepository(for: vault)

        try await repository.recordSnapshot()

        let snapshotReference = try latestSnapshotReference(in: vault)
        #expect(!snapshotReference.isEmpty)
    }

    @Test
    func `expired snapshot deadline does not enumerate private leftovers`() throws {
        let vault = try makeVault()
        defer { vault.remove() }

        do {
            _ = try GitSnapshotIndexWorkspace.create(
                in: vault.dataDirectory.snapshotWorkspaceDirectoryURL,
                deadline: .now.advanced(by: .seconds(-1))
            )
            Issue.record("Expected workspace cleanup deadline failure")
        } catch let error as VaultVersioningError {
            guard case .gitCommandTimedOut(let arguments) = error else {
                Issue.record("Expected a typed Git deadline, got \(error)")
                return
            }
            #expect(arguments == ["snapshot-workspace-scavenge"])
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: vault.dataDirectory.snapshotWorkspaceDirectoryURL.path
            ).isEmpty
        )
    }

    /// Filesystem state outside `notes/` is never part of snapshot discovery.
    @Test
    func `unreadable third party state outside notes is irrelevant`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let thirdParty = vault.root.appendingPathComponent(".obsidian")
        try FileManager.default.createDirectory(
            at: thirdParty,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o000]
        )
        defer { _ = Darwin.chmod(thirdParty.path, 0o700) }
        try Data("snapshot".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )

        try await makeRepository(for: vault).recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)

        #expect(
            try runSnapshotGit(
                ["ls-tree", "-r", "--name-only", snapshotReference],
                in: vault
            ) == "notes/memory.md"
        )
    }

    /// Git otherwise stages an embedded repository as a non-recoverable
    /// gitlink while reporting success. Recovery must fail closed instead of
    /// claiming that the nested note bytes were snapshotted.
    @Test
    func `embedded repository below notes cannot become a silent gitlink`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let embedded = vault.notes.appendingPathComponent(
            "embedded",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: embedded,
            withIntermediateDirectories: true
        )
        try Data("must remain recoverable".utf8).write(
            to: embedded.appendingPathComponent("memory.md"),
            options: .atomic
        )
        _ = try runGit(["init"], in: embedded)
        _ = try runGit(["add", "--all"], in: embedded)
        _ = try runGit([
            "-c", "user.name=Test",
            "-c", "user.email=test@example.invalid",
            "commit", "--no-gpg-sign", "-m", "Embedded baseline",
        ], in: embedded)

        do {
            try await makeRepository(for: vault).recordSnapshot()
            Issue.record("Expected the embedded repository to fail closed")
        } catch let error as VaultVersioningError {
            guard case .embeddedRepositoryBelowNotes = error else {
                Issue.record("Expected embedded-repository failure, got \(error)")
                return
            }
        }
        #expect(try latestSnapshotReference(in: vault).isEmpty)
    }

    /// Recovery stores note bytes, never filesystem indirections to content
    /// outside the protected vault traversal policy.
    @Test(arguments: ["root", "nested"])
    func `symbolic links below the notes boundary fail closed`(_ fixture: String) async throws {
        let vault = try makeVault(createNotesDirectory: fixture != "root")
        defer { vault.remove() }
        let outside = vault.cleanupRoot.appendingPathComponent(
            "outside",
            isDirectory: fixture == "root"
        )
        if fixture == "root" {
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: true
            )
            try Data("outside".utf8).write(
                to: outside.appendingPathComponent("memory.md"),
                options: .atomic
            )
            try FileManager.default.createSymbolicLink(
                at: vault.notes,
                withDestinationURL: outside
            )
        } else {
            try Data("outside".utf8).write(to: outside, options: .atomic)
            try FileManager.default.createSymbolicLink(
                at: vault.notes.appendingPathComponent("linked.md"),
                withDestinationURL: outside
            )
        }

        do {
            try await makeRepository(for: vault).recordSnapshot()
            Issue.record("Expected unsupported notes entry failure")
        } catch let error as VaultVersioningError {
            guard case .unsupportedEntryBelowNotes = error else {
                Issue.record("Expected unsupported notes entry, got \(error)")
                return
            }
        }
        #expect(try latestSnapshotReference(in: vault).isEmpty)
    }

    /// Git silently ignores FIFOs instead of representing them in an index.
    /// Recovery must reject that unsupported state rather than accept an
    /// incomplete or empty snapshot.
    @Test
    func `special filesystem entries below notes fail closed`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let pipe = vault.notes.appendingPathComponent("live.pipe")
        #expect(Darwin.mkfifo(pipe.path, 0o600) == 0)

        do {
            try await makeRepository(for: vault).recordSnapshot()
            Issue.record("Expected unsupported notes entry failure")
        } catch let error as VaultVersioningError {
            guard case .unsupportedEntryBelowNotes = error else {
                Issue.record("Expected unsupported notes entry, got \(error)")
                return
            }
        }
        #expect(try latestSnapshotReference(in: vault).isEmpty)
    }

    /// The work-tree pathname is not authority after the validated vault root
    /// has been moved and replaced by a different directory.
    @Test
    func `replaced vault root cannot publish bytes from another directory`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        try Data("original".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )
        let moved = vault.cleanupRoot.appendingPathComponent(
            "moved-vault",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: vault.root, to: moved)
        try FileManager.default.createDirectory(
            at: vault.notes,
            withIntermediateDirectories: true
        )
        try Data("replacement".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )

        do {
            try await repository.recordSnapshot()
            Issue.record("Expected changed vault root failure")
        } catch let error as VaultVersioningError {
            guard case .vaultRootChanged = error else {
                Issue.record("Expected changed vault root, got \(error)")
                return
            }
        }
        #expect(try latestSnapshotReference(in: vault).isEmpty)
    }

    @Test
    func `vault replacement cannot pass the empty first snapshot path`() async throws {
        let vault = try makeVault(createNotesDirectory: false)
        defer { vault.remove() }
        let moved = vault.cleanupRoot.appendingPathComponent(
            "moved-empty-vault",
            isDirectory: true
        )
        let repository = try GitRepository(
            vaultURL: vault.root,
            dataDirectory: vault.dataDirectory,
            postStageObserver: {
                try FileManager.default.moveItem(at: vault.root, to: moved)
                try FileManager.default.createDirectory(
                    at: vault.root,
                    withIntermediateDirectories: true
                )
            }
        )

        do {
            try await repository.recordSnapshot()
            Issue.record("Expected changed vault root failure")
        } catch let error as VaultVersioningError {
            guard case .vaultRootChanged = error else {
                Issue.record("Expected changed vault root, got \(error)")
                return
            }
        }
        #expect(try latestSnapshotReference(in: vault).isEmpty)
    }

    @Test
    func `vault replacement cannot pass the unchanged tree path`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        try Data("same tree".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )
        try await makeRepository(for: vault).recordSnapshot()
        let referenceBefore = try latestSnapshotReference(in: vault)
        let moved = vault.cleanupRoot.appendingPathComponent(
            "moved-unchanged-vault",
            isDirectory: true
        )
        let repository = try GitRepository(
            vaultURL: vault.root,
            dataDirectory: vault.dataDirectory,
            postStageObserver: {
                try FileManager.default.moveItem(at: vault.root, to: moved)
                try FileManager.default.createDirectory(
                    at: vault.notes,
                    withIntermediateDirectories: true
                )
                try Data("same tree".utf8).write(
                    to: vault.notes.appendingPathComponent("memory.md"),
                    options: .atomic
                )
            }
        )

        do {
            try await repository.recordSnapshot()
            Issue.record("Expected changed vault root failure")
        } catch let error as VaultVersioningError {
            guard case .vaultRootChanged = error else {
                Issue.record("Expected changed vault root, got \(error)")
                return
            }
        }
        #expect(try latestSnapshotReference(in: vault) == referenceBefore)
    }

    /// Repository hooks and fsmonitor are interactive Git configuration. No
    /// product plumbing command may execute them, even with a private index.
    @Test
    func `snapshot disables every repository hook and fsmonitor command`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        _ = try runGit(["init"], in: vault.root)
        let hooks = vault.root.appendingPathComponent("third-party-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hookMarker = vault.root.appendingPathComponent("hook-invoked")
        let monitorMarker = vault.root.appendingPathComponent("monitor-invoked")
        let hookScript = "#!/bin/sh\n/usr/bin/touch '\(hookMarker.path)'\nexit 0\n"
        for name in ["post-index-change", "reference-transaction"] {
            let script = hooks.appendingPathComponent(name)
            try Data(hookScript.utf8).write(to: script, options: .atomic)
            #expect(Darwin.chmod(script.path, 0o700) == 0)
        }
        let monitor = vault.root.appendingPathComponent("third-party-monitor")
        try Data(
            "#!/bin/sh\n/usr/bin/touch '\(monitorMarker.path)'\nexit 0\n".utf8
        ).write(to: monitor, options: .atomic)
        #expect(Darwin.chmod(monitor.path, 0o700) == 0)
        _ = try runGit(["config", "core.hooksPath", hooks.path], in: vault.root)
        _ = try runGit(["config", "core.fsmonitor", monitor.path], in: vault.root)
        try Data("snapshot".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )

        try await makeRepository(for: vault).recordSnapshot()

        #expect(!FileManager.default.fileExists(atPath: hookMarker.path))
        #expect(!FileManager.default.fileExists(atPath: monitorMarker.path))
    }

    /// Split-index configuration must not create shared index artifacts in the
    /// user's Git metadata when the product writes its private index.
    @Test
    func `snapshot disables repository split index configuration`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        _ = try runGit(["init"], in: vault.root)
        _ = try runGit(["config", "core.splitIndex", "true"], in: vault.root)
        let commonDirectory = try gitDirectory(in: vault.root, argument: "--git-common-dir")
        let before = try sharedIndexNames(in: commonDirectory)
        try Data("snapshot".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )

        try await makeRepository(for: vault).recordSnapshot()

        #expect(try sharedIndexNames(in: commonDirectory) == before)
    }

    /// A user's broken HEAD and real index are irrelevant because product
    /// snapshots use neither. Even lock sentinels must survive byte-for-byte.
    @Test
    func `snapshot is independent of broken user HEAD and index`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        _ = try runGit(["init"], in: vault.root)
        let headURL = try gitPath("HEAD", in: vault.root)
        let indexURL = try gitPath("index", in: vault.root)
        let headLockURL = try gitPath("HEAD.lock", in: vault.root)
        let indexLockURL = try gitPath("index.lock", in: vault.root)
        let missingCommit = Data((String(repeating: "1", count: 40) + "\n").utf8)
        let corruptIndex = Data("not a Git index".utf8)
        let headLock = Data("foreign HEAD lock".utf8)
        let indexLock = Data("foreign index lock".utf8)
        try missingCommit.write(to: headURL, options: .atomic)
        try corruptIndex.write(to: indexURL, options: .atomic)
        try headLock.write(to: headLockURL, options: .withoutOverwriting)
        try indexLock.write(to: indexLockURL, options: .withoutOverwriting)
        try Data("snapshot".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )

        try await makeRepository(for: vault).recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)

        #expect(try Data(contentsOf: headURL) == missingCommit)
        #expect(try Data(contentsOf: indexURL) == corruptIndex)
        #expect(try Data(contentsOf: headLockURL) == headLock)
        #expect(try Data(contentsOf: indexLockURL) == indexLock)
        #expect(
            try runSnapshotGit(
                ["show", "\(snapshotReference):notes/memory.md"],
                in: vault
            ) == "snapshot"
        )
    }

    /// Local `core.worktree` is user configuration and must not redirect the
    /// product's fixed notes scope into another checkout.
    @Test
    func `repository worktree configuration cannot redirect snapshot reads`() async throws {
        let vault = try makeVault()
        let redirected = try makeVault()
        defer {
            redirected.remove()
            vault.remove()
        }
        _ = try runGit(["init"], in: vault.root)
        _ = try runGit(
            ["config", "core.worktree", redirected.root.path],
            in: vault.root
        )
        try Data("correct vault".utf8).write(
            to: vault.notes.appendingPathComponent("correct.md"),
            options: .atomic
        )
        try Data("redirected vault".utf8).write(
            to: redirected.notes.appendingPathComponent("wrong.md"),
            options: .atomic
        )

        try await makeRepository(for: vault).recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)

        #expect(
            try runSnapshotGit(
                ["ls-tree", "-r", "--name-only", snapshotReference],
                in: vault
            ) == "notes/correct.md"
        )
    }

    /// Repository attributes belong to interactive Git. They cannot launch a
    /// filter or transform the exact note bytes stored for product recovery.
    @Test
    func `snapshot ignores repository attributes and stores exact note bytes`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        _ = try runGit(["init"], in: vault.root)
        let attributes = vault.root.appendingPathComponent(".gitattributes")
        let attributeRule = "notes/*.md filter=mutate text eol=crlf ident\n"
        try Data(attributeRule.utf8).write(to: attributes, options: .atomic)
        try Data("*.md filter=mutate text eol=lf ident\n".utf8).write(
            to: vault.notes.appendingPathComponent(".gitattributes"),
            options: .atomic
        )
        try Data(attributeRule.utf8).write(
            to: try gitPath("info/attributes", in: vault.root),
            options: .atomic
        )
        let marker = vault.root.appendingPathComponent("filter-invoked")
        let filter = vault.root.appendingPathComponent("third-party-filter")
        try Data(
            "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n/usr/bin/tr '[:lower:]' '[:upper:]'\n".utf8
        ).write(to: filter, options: .atomic)
        #expect(Darwin.chmod(filter.path, 0o700) == 0)
        _ = try runGit(["config", "filter.mutate.clean", filter.path], in: vault.root)
        _ = try runGit(["config", "filter.mutate.required", "true"], in: vault.root)
        let repository = try makeRepository(for: vault)
        try await repository.recordSnapshot()
        _ = try runSnapshotGit(
            ["config", "filter.mutate.clean", filter.path],
            in: vault
        )
        _ = try runSnapshotGit(
            ["config", "filter.mutate.required", "true"],
            in: vault
        )
        let exactBytes = Data("lowercase\r\n$Id: injected $\r\n".utf8)
        try exactBytes.write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )
        let binaryBytes = Data([0x00, 0x0d, 0x0a, 0xff, 0x24, 0x49, 0x64, 0x24])
        try binaryBytes.write(
            to: vault.notes.appendingPathComponent("binary.md"),
            options: .atomic
        )

        try await repository.recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)
        let stored = try runSnapshotGitBytes(
            ["show", "\(snapshotReference):notes/memory.md"],
            in: vault
        )
        let storedBinary = try runSnapshotGitBytes(
            ["show", "\(snapshotReference):notes/binary.md"],
            in: vault
        )

        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(stored == exactBytes)
        #expect(storedBinary == binaryBytes)
    }

    /// The command-line attribute source is a Git object. Product garbage
    /// collection must not make that object unreachable and break a later
    /// exact-byte snapshot.
    @Test
    func `attribute isolation survives product repository pruning`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let note = vault.notes.appendingPathComponent("memory.md")
        try Data("first\r\n".utf8).write(to: note, options: .atomic)
        try await repository.recordSnapshot()

        _ = try runSnapshotGit(
            ["reflog", "expire", "--expire=now", "--all"],
            in: vault
        )
        _ = try runSnapshotGit(["prune", "--expire=now"], in: vault)
        try Data("second\r\n".utf8).write(to: note, options: .atomic)

        try await repository.recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)
        #expect(
            try runSnapshotGitBytes(
                ["show", "\(snapshotReference):notes/memory.md"],
                in: vault
            ) == Data("second\r\n".utf8)
        )
    }

    /// The support volume's case policy must not be mistaken for the vault
    /// volume's path identity when a note changes only its filename case.
    @Test
    func `case-only note rename is recorded exactly`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let uppercase = vault.notes.appendingPathComponent("Memory.md")
        let lowercase = vault.notes.appendingPathComponent("memory.md")
        try Data("case-sensitive identity".utf8).write(
            to: uppercase,
            options: .atomic
        )
        try await repository.recordSnapshot()

        try FileManager.default.moveItem(at: uppercase, to: lowercase)
        try await repository.recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)

        #expect(
            try runSnapshotGit(
                ["ls-tree", "-r", "--name-only", snapshotReference, "--", "notes"],
                in: vault
            ) == "notes/memory.md"
        )
    }

    @Test
    func `snapshot deadline is bounded and a later retry succeeds`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        try Data("retry me".utf8).write(
            to: vault.notes.appendingPathComponent("memory.md"),
            options: .atomic
        )
        let heldLock = POSIXAdvisoryFileLock(
            url: vault.dataDirectory.lockDirectoryURL
                .appendingPathComponent("git-snapshot.lock")
        )
        let heldLease = try await heldLock.acquire(.exclusive)
        defer { heldLease.release() }
        let bounded = try GitRepository(
            vaultURL: vault.root,
            dataDirectory: vault.dataDirectory,
            snapshotTimeout: .milliseconds(50)
        )
        let clock = ContinuousClock()
        let started = clock.now

        do {
            try await bounded.recordSnapshot()
            Issue.record("Expected the complete snapshot deadline to expire")
        } catch let error as VaultVersioningError {
            guard case .gitCommandTimedOut = error else {
                Issue.record("Expected a typed Git deadline, got \(error)")
                return
            }
        }

        #expect(started.duration(to: clock.now) < .seconds(4))
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: vault.dataDirectory.snapshotWorkspaceDirectoryURL.path
            ).isEmpty
        )

        heldLease.release()
        try await makeRepository(for: vault).recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)
        #expect(
            try runSnapshotGit(
                ["show", "\(snapshotReference):notes/memory.md"],
                in: vault
            ) == "retry me"
        )
    }

    @Test
    func `snapshot deadline is checked before an empty tree returns`() async throws {
        let vault = try makeVault(createNotesDirectory: false)
        defer { vault.remove() }
        let observer = PostStageObserverProbe()
        let bounded = try GitRepository(
            vaultURL: vault.root,
            dataDirectory: vault.dataDirectory,
            snapshotTimeout: .seconds(2),
            postStageObserver: {
                observer.mark()
                Thread.sleep(forTimeInterval: 2.25)
            }
        )

        do {
            try await bounded.recordSnapshot()
            Issue.record("Expected the complete snapshot deadline to expire")
        } catch let error as VaultVersioningError {
            guard case .gitCommandTimedOut(let arguments) = error else {
                Issue.record("Expected a typed Git deadline, got \(error)")
                return
            }
            #expect(arguments == ["snapshot-filesystem-scan"])
        }
        #expect(observer.observed)
    }

    /// Exercises separate runtime boundaries sharing the same advisory lock.
    @Test
    func `concurrent mutation chains share one reliable Git transaction`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let agentCount = 16
        let lockURL = vault.root.appendingPathComponent(".vault-access.lock")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for agent in 0..<agentCount {
                group.addTask {
                    let repository = try makeRepository(for: vault)
                    let access = VaultAccessCoordinator(lockURL: lockURL)
                    try await access.withMutation {
                        try Data("agent \(agent)".utf8).write(
                            to: vault.notes.appendingPathComponent("note-\(agent).md"),
                            options: .atomic
                        )
                        try await repository.recordSnapshot()
                    }
                }
            }

            try await group.waitForAll()
        }

        let snapshotReference = try latestSnapshotReference(in: vault)
        let trackedNotes = try runSnapshotGit(
            ["ls-tree", "-r", "--name-only", snapshotReference, "--", "notes"],
            in: vault
        ).split(separator: "\n")

        #expect(trackedNotes.count == agentCount)
        #expect(!FileManager.default.fileExists(atPath: vault.root.appendingPathComponent(".git").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: vault.root
                    .appendingPathComponent(".git/index.lock")
                    .path(percentEncoded: false)
            )
        )
    }

    /// When two runtimes see the same pending bytes, their shared mutation lease
    /// permits one coalesced snapshot and one clean no-op.
    @Test
    func `two runtimes can share one coalesced vault snapshot`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let firstAgent = try makeRepository(for: vault)
        let secondAgent = try makeRepository(for: vault)
        let lockURL = vault.root.appendingPathComponent(".vault-access.lock")
        let firstAccess = VaultAccessCoordinator(lockURL: lockURL)
        let secondAccess = VaultAccessCoordinator(lockURL: lockURL)

        try Data("first agent".utf8).write(
            to: vault.notes.appendingPathComponent("first.md"),
            options: .atomic
        )
        try Data("second agent".utf8).write(
            to: vault.notes.appendingPathComponent("second.md"),
            options: .atomic
        )

        async let firstSnapshot: Void = firstAccess.withMutation {
            try await firstAgent.recordSnapshot()
        }
        async let secondSnapshot: Void = secondAccess.withMutation {
            try await secondAgent.recordSnapshot()
        }
        _ = try await (firstSnapshot, secondSnapshot)
        let snapshotReference = try latestSnapshotReference(in: vault)

        let committedNotes = try runSnapshotGit(
            [
                "show", "--pretty=", "--name-only", snapshotReference,
                "--", "notes",
            ],
            in: vault
        ).split(separator: "\n").map(String.init)

        #expect(Set(committedNotes) == ["notes/first.md", "notes/second.md"])
        #expect(
            try runSnapshotGit(
                ["rev-list", "--count", snapshotReference],
                in: vault
            ) == "1"
        )
        #expect(!FileManager.default.fileExists(atPath: vault.root.appendingPathComponent(".git").path))
    }

    /// Verifies that removing the final note is staged even though `notes/` no
    /// longer exists in the working tree.
    @Test
    func `deleting every note is recorded`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        let note = vault.notes.appendingPathComponent("temporary.md")
        try Data("temporary".utf8).write(to: note, options: .atomic)
        try await repository.recordSnapshot()

        try FileManager.default.removeItem(at: vault.notes)
        try await repository.recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)

        #expect(
            try runSnapshotGit(
                ["ls-tree", "-r", "--name-only", snapshotReference, "--", "notes"],
                in: vault
            ).isEmpty
        )
        #expect(
            try runSnapshotGit(
                ["rev-list", "--count", snapshotReference],
                in: vault
            ) == "2"
        )
    }

    /// Deletion detection cannot depend on collecting an unbounded list of
    /// every formerly tracked path into the subprocess output buffer.
    @Test
    func `deleting a large notes tree stays bounded and is recorded`() async throws {
        let vault = try makeVault()
        defer { vault.remove() }
        let repository = try makeRepository(for: vault)
        for index in 0..<600 {
            let name = String(format: "%04d-%@.md", index, String(repeating: "x", count: 64))
            try Data("note \(index)".utf8).write(
                to: vault.notes.appendingPathComponent(name),
                options: .atomic
            )
        }
        try await repository.recordSnapshot()

        try FileManager.default.removeItem(at: vault.notes)
        try await repository.recordSnapshot()
        let snapshotReference = try latestSnapshotReference(in: vault)

        #expect(
            try runSnapshotGit(
                ["ls-tree", "-r", "--name-only", snapshotReference, "--", "notes"],
                in: vault
            ).isEmpty
        )
    }
}

private final class PostStageObserverProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var observed: Bool {
        lock.withLock { value }
    }

    func mark() {
        lock.withLock { value = true }
    }
}

private final class GitExecutableResolverProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let initial: URL
    private let fallback: URL
    private var callCount = 0

    init(initial: URL, fallback: URL) {
        self.initial = initial
        self.fallback = fallback
    }

    var calls: Int { lock.withLock { callCount } }

    func resolve() throws -> URL {
        lock.withLock {
            callCount += 1
            return callCount == 1 ? initial : fallback
        }
    }
}

private final class GitExecutableValidatorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    var calls: Int { lock.withLock { callCount } }

    func validate(_ url: URL) -> Bool {
        lock.withLock {
            callCount += 1
            return false
        }
    }
}

private extension `GitRepository snapshots` {
    /// Filesystem locations owned by one isolated integration test.
    struct TestVault: Sendable {
        let cleanupRoot: URL
        let root: URL
        let notes: URL
        let dataDirectory: VaultDataDirectory

        func remove() {
            try? FileManager.default.removeItem(at: cleanupRoot)
        }
    }

    /// Creates an isolated vault and the parent directory required by its lock.
    func makeVault(createNotesDirectory: Bool = true) throws -> TestVault {
        let cleanupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitRepositoryTests-\(UUID().uuidString)")
        let root = cleanupRoot.appendingPathComponent("vault", isDirectory: true)
        let notes = root.appendingPathComponent("notes")

        try FileManager.default.createDirectory(
            at: createNotesDirectory ? notes : root,
            withIntermediateDirectories: true
        )

        return TestVault(
            cleanupRoot: cleanupRoot,
            root: root,
            notes: notes,
            dataDirectory: try VaultDataDirectory.prepare(
                vaultPath: root.path,
                supportRoot: cleanupRoot.appendingPathComponent("support", isDirectory: true)
            )
        )
    }

    /// Constructs an independently isolated Git boundary for this vault.
    func makeRepository(for vault: TestVault) throws -> GitRepository {
        try GitRepository(vaultURL: vault.root, dataDirectory: vault.dataDirectory)
    }

    /// Runs a small Git setup or assertion command and returns trimmed output.
    func runGit(
        _ arguments: [String],
        in repository: URL,
        fixedWorktree: URL? = nil,
        gitDirectory: URL? = nil
    ) throws -> String {
        String(
            decoding: try runGitBytes(
                arguments,
                in: repository,
                fixedWorktree: fixedWorktree,
                gitDirectory: gitDirectory
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a Git assertion without text normalization so exact snapshot bytes
    /// can be compared with the vault source.
    func runGitBytes(
        _ arguments: [String],
        in repository: URL,
        fixedWorktree: URL? = nil,
        gitDirectory: URL? = nil
    ) throws -> Data {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        if let gitDirectory {
            process.arguments = [
                "--git-dir=\(gitDirectory.path(percentEncoded: false))",
                "--work-tree=\(repository.path(percentEncoded: false))",
                "-c", "core.bare=false",
            ] + arguments
        } else {
            process.arguments = [
                "-C",
                repository.path(percentEncoded: false),
            ] + (fixedWorktree.map { ["--work-tree=\($0.path)"] } ?? []) + arguments
        }
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw TestGitError(
                arguments: arguments,
                message: String(decoding: error, as: UTF8.self)
            )
        }

        return output
    }

    /// Resolves Git administrative files correctly for ordinary and linked worktrees.
    func gitPath(_ name: String, in repository: URL) throws -> URL {
        let rawPath = try runGit(["rev-parse", "--git-path", name], in: repository)
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath)
        }
        return repository.appendingPathComponent(rawPath).standardizedFileURL
    }

    /// Returns the newest immutable product snapshot reference.
    func latestSnapshotReference(in vault: TestVault) throws -> String {
        guard FileManager.default.fileExists(
            atPath: vault.dataDirectory.snapshotRepositoryURL
                .appendingPathComponent("HEAD").path
        ) else { return "" }
        return try runSnapshotGit([
            "for-each-ref",
            "--sort=-refname",
            "--count=1",
            "--format=%(refname)",
            GitRepository.snapshotReferencePrefix,
        ], in: vault)
    }

    func runSnapshotGit(_ arguments: [String], in vault: TestVault) throws -> String {
        try runGit(
            arguments,
            in: vault.root,
            gitDirectory: vault.dataDirectory.snapshotRepositoryURL
        )
    }

    func runSnapshotGitBytes(_ arguments: [String], in vault: TestVault) throws -> Data {
        try runGitBytes(
            arguments,
            in: vault.root,
            gitDirectory: vault.dataDirectory.snapshotRepositoryURL
        )
    }

    func snapshotGitPath(_ name: String, in vault: TestVault) throws -> URL {
        let rawPath = try runSnapshotGit(
            ["rev-parse", "--git-path", name],
            in: vault
        )
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath)
        }
        return vault.dataDirectory.snapshotRepositoryURL
            .appendingPathComponent(rawPath).standardizedFileURL
    }

    /// Resolves the current worktree or common Git directory.
    func gitDirectory(in repository: URL, argument: String) throws -> URL {
        let rawPath = try runGit(["rev-parse", argument], in: repository)
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath, isDirectory: true)
        }
        return repository.appendingPathComponent(rawPath).standardizedFileURL
    }

    func sharedIndexNames(in directory: URL) throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix("sharedindex.") }
        )
    }

    /// A compact diagnostic when a read-only Git assertion command fails.
    struct TestGitError: Error, CustomStringConvertible {
        let arguments: [String]
        let message: String

        var description: String {
            "git \(arguments.joined(separator: " ")) failed: \(message)"
        }
    }
}
