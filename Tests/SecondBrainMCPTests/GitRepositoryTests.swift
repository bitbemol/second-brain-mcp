import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("GitRepository")
struct GitRepositoryTests {
    private func makeRepository() throws -> (String, GitRepository) {
        let root = NSTemporaryDirectory() + "GitRepositoryTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        return (root, GitRepository(repoPath: root))
    }

    private func commitCurrentMarkdown(
        _ git: GitRepository,
        root: String,
        path: String,
        message: String,
        identity: GitMutationIdentity? = nil
    ) async throws {
        let data = try Data(
            contentsOf: URL(fileURLWithPath: root).appendingPathComponent(path)
        )
        try await git.commitChange(
            file: path,
            expectedRevision: FileSnapshot(
                data: data,
                modifiedDate: nil
            ).revision,
            maximumBytes: FileFormat.markdown.maximumFileBytes,
            message: message,
            identity: identity
        )
    }

    private func runGit(_ arguments: [String], at root: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitTestError.commandFailed
        }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    private func gitExitStatus(_ arguments: [String], at root: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("Initializes a repository and private ignore rules")
    func initializesRepository() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()

        #expect(FileManager.default.fileExists(atPath: root + "/.git"))
        let ignore = try String(
            contentsOfFile: root + "/.git/info/exclude",
            encoding: .utf8
        )
        #expect(ignore.contains("/references/"))
        #expect(try runGit(["rev-list", "--count", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test("Initialization preserves a user gitignore")
    func preservesUserGitignore() async throws {
        let (root, git) = try makeRepository()
        let customIgnore = "private-user-rule/\n"
        try customIgnore.write(
            toFile: root + "/.gitignore",
            atomically: true,
            encoding: .utf8
        )

        try await git.ensureRepository()

        #expect(
            try String(contentsOfFile: root + "/.gitignore", encoding: .utf8)
                == customIgnore
        )
    }

    @Test("Existing repositories exclude references before startup snapshot")
    func existingRepositoryExcludesReferences() async throws {
        let (root, git) = try makeRepository()
        _ = try runGit(["init"], at: root)
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        try Data("pdf".utf8).write(
            to: URL(fileURLWithPath: root + "/references/book.pdf")
        )
        try "note".write(
            toFile: root + "/notes/external.md",
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            atPath: root + "/notes/references",
            withIntermediateDirectories: true
        )
        try "nested note".write(
            toFile: root + "/notes/references/project.md",
            atomically: true,
            encoding: .utf8
        )

        try await git.ensureRepository()

        let committedPaths = try runGit(
            ["show", "--pretty=format:", "--name-only", "HEAD"],
            at: root
        )
        #expect(committedPaths.contains("notes/external.md"))
        #expect(committedPaths.contains("notes/references/project.md"))
        #expect(!committedPaths.contains("references/book.pdf"))
        #expect(
            try runGit(["check-ignore", "references/book.pdf"], at: root)
                .contains("references/book.pdf")
        )
        #expect(
            try gitExitStatus(
                ["check-ignore", "notes/references/project.md"],
                at: root
            ) != 0
        )
    }

    @Test("Adds a fallback commit identity when configuration is empty")
    func suppliesFallbackIdentity() async throws {
        let (root, git) = try makeRepository()
        _ = try runGit(["init"], at: root)
        _ = try runGit(["config", "user.name", ""], at: root)
        _ = try runGit(["config", "user.email", ""], at: root)
        try "note".write(
            toFile: root + "/notes/external.md",
            atomically: true,
            encoding: .utf8
        )

        try await git.ensureRepository()

        #expect(
            try runGit(["config", "--get", "user.name"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "SecondBrainMCP"
        )
        #expect(
            try runGit(["config", "--get", "user.email"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "secondbrainmcp@localhost"
        )
    }

    @Test("Treats pathspec metacharacters as literal filenames")
    func commitsLiteralPathspecFilename() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        try "user edit".write(
            toFile: root + "/notes/sibling.md",
            atomically: true,
            encoding: .utf8
        )
        try "literal".write(
            toFile: root + "/notes/*.md",
            atomically: true,
            encoding: .utf8
        )
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "literal-path")

        try await commitCurrentMarkdown(
            git,
            root: root,
            path: "notes/*.md",
            message: "[SecondBrainMCP] Created markdown",
            identity: GitMutationIdentity(
                identifier: identifier,
                fingerprint: fingerprint
            )
        )

        let committedPaths = try runGit(
            ["show", "--pretty=format:", "--name-only", "HEAD"],
            at: root
        )
        #expect(committedPaths.contains("notes/*.md"))
        #expect(!committedPaths.contains("notes/sibling.md"))
        #expect(
            try runGit(["status", "--porcelain"], at: root)
                .contains("notes/sibling.md")
        )
        let foundLiteral = try await git.containsMutationCommit(
            identifier: identifier,
            fingerprint: fingerprint
        )
        #expect(foundLiteral)
    }

    @Test("Commits a scoped file change")
    func commitsChange() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        try "content".write(toFile: root + "/notes/file.md", atomically: true, encoding: .utf8)

        try await commitCurrentMarkdown(
            git,
            root: root,
            path: "notes/file.md",
            message: "[SecondBrainMCP] Created markdown"
        )

        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
        #expect(try runGit(["rev-list", "--count", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    @Test("Commits a deletion")
    func commitsDeletion() async throws {
        let (root, git) = try makeRepository()
        try "content".write(toFile: root + "/notes/file.md", atomically: true, encoding: .utf8)
        try await git.ensureRepository()
        try FileManager.default.removeItem(atPath: root + "/notes/file.md")

        try await git.commitDeletion(path: "notes/file.md", message: "[SecondBrainMCP] Deleted markdown")

        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
        #expect(try runGit(["rev-list", "--count", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    @Test("An untracked deletion records an intentional empty marker commit")
    func untrackedDeletionCommitsMarker() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        try "external".write(
            toFile: root + "/notes/external.md",
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.removeItem(atPath: root + "/notes/external.md")
        let before = try runGit(["rev-parse", "HEAD^{tree}"], at: root)

        try await git.commitDeletion(
            path: "notes/external.md",
            message: "untracked deletion marker"
        )

        #expect(try runGit(["rev-parse", "HEAD^{tree}"], at: root) == before)
        #expect(try runGit(["log", "-1", "--pretty=%s"], at: root)
            .contains("untracked deletion marker"))
    }

    @Test("An empty directory move records an intentional marker commit")
    func emptyDirectoryMoveCommitsMarker() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        try FileManager.default.createDirectory(
            atPath: root + "/notes/source/empty",
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: root + "/notes/completed",
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            atPath: root + "/notes/source/empty",
            toPath: root + "/notes/completed/empty"
        )
        let before = try runGit(["rev-parse", "HEAD^{tree}"], at: root)
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "empty-move")

        try await git.commitMove(
            sourcePath: "notes/source/empty",
            destinationPath: "notes/completed/empty",
            message: "empty move marker",
            identity: GitMutationIdentity(
                identifier: identifier,
                fingerprint: fingerprint
            )
        )

        #expect(try runGit(["rev-parse", "HEAD^{tree}"], at: root) == before)
        #expect(try runGit(["log", "-1", "--pretty=%s"], at: root)
            .contains("empty move marker"))
        #expect(try await git.containsMutationCommit(
            identifier: identifier,
            fingerprint: fingerprint
        ))
    }

    @Test("A deletion does not stage an edited sibling")
    func deletionLeavesSiblingEditUncommitted() async throws {
        let (root, git) = try makeRepository()
        try "delete me".write(
            toFile: root + "/notes/deleted.md",
            atomically: true,
            encoding: .utf8
        )
        try "original".write(
            toFile: root + "/notes/sibling.md",
            atomically: true,
            encoding: .utf8
        )
        try await git.ensureRepository()

        try FileManager.default.removeItem(atPath: root + "/notes/deleted.md")
        try "external edit".write(
            toFile: root + "/notes/sibling.md",
            atomically: true,
            encoding: .utf8
        )

        try await git.commitDeletion(
            path: "notes/deleted.md",
            message: "[SecondBrainMCP] Deleted markdown"
        )

        let status = try runGit(["status", "--porcelain"], at: root)
        #expect(status.contains(" M notes/sibling.md"))
        #expect(!status.contains("deleted.md"))
        let committedPaths = try runGit(
            ["show", "--pretty=format:", "--name-only", "HEAD"],
            at: root
        )
        #expect(committedPaths.contains("notes/deleted.md"))
        #expect(!committedPaths.contains("notes/sibling.md"))
    }

    @Test("A file commit preserves unrelated staged work")
    func fileCommitLeavesUnrelatedIndexEntryStaged() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        try "user work".write(
            toFile: root + "/notes/unrelated.md",
            atomically: true,
            encoding: .utf8
        )
        _ = try runGit(["add", "--", "notes/unrelated.md"], at: root)
        try "managed".write(
            toFile: root + "/notes/managed.md",
            atomically: true,
            encoding: .utf8
        )

        try await commitCurrentMarkdown(
            git,
            root: root,
            path: "notes/managed.md",
            message: "[SecondBrainMCP] Created markdown"
        )

        let committedPaths = try runGit(
            ["show", "--pretty=format:", "--name-only", "HEAD"],
            at: root
        )
        #expect(committedPaths.contains("notes/managed.md"))
        #expect(!committedPaths.contains("notes/unrelated.md"))
        #expect(
            try runGit(["diff", "--cached", "--name-only"], at: root)
                .contains("notes/unrelated.md")
        )
    }

    @Test("Post-validation replacement cannot alter a file commit")
    func fileCommitUsesValidatedImmutableBlob() async throws {
        let (root, initialGit) = try makeRepository()
        try await initialGit.ensureRepository()
        let path = "notes/managed.md"
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        let safe = Data("validated bytes".utf8)
        try safe.write(to: url, options: .atomic)
        let git = GitRepository(repoPath: root) {
            try Data("api_key=abcdefghijklmnop1234567890".utf8)
                .write(to: url, options: .atomic)
        }

        try await git.commitChange(
            file: path,
            expectedRevision: FileSnapshot(
                data: safe,
                modifiedDate: nil
            ).revision,
            maximumBytes: FileFormat.markdown.maximumFileBytes,
            message: "immutable file"
        )

        #expect(try runGit(["show", "HEAD:\(path)"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == "validated bytes")
        #expect(try String(contentsOf: url, encoding: .utf8)
            .contains("api_key="))
        #expect(try !runGit(["status", "--porcelain"], at: root).isEmpty)
    }

    @Test("Post-validation recreation cannot alter a deletion commit")
    func deletionCommitUsesValidatedImmutableTree() async throws {
        let (root, initialGit) = try makeRepository()
        let path = "notes/deleted.md"
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        try Data("tracked".utf8).write(to: url, options: .atomic)
        try await initialGit.ensureRepository()
        try FileManager.default.removeItem(at: url)
        let git = GitRepository(repoPath: root) {
            try Data("api_key=abcdefghijklmnop1234567890".utf8)
                .write(to: url, options: .atomic)
        }

        try await git.commitDeletion(path: path, message: "immutable deletion")

        #expect(try gitExitStatus(["cat-file", "-e", "HEAD:\(path)"], at: root)
            != 0)
        #expect(try String(contentsOf: url, encoding: .utf8)
            .contains("api_key="))
        #expect(try !runGit(["status", "--porcelain"], at: root).isEmpty)
    }

    @Test("A deletion commit preserves unrelated staged work")
    func deletionCommitLeavesUnrelatedIndexEntryStaged() async throws {
        let (root, git) = try makeRepository()
        try "delete me".write(
            toFile: root + "/notes/deleted.md",
            atomically: true,
            encoding: .utf8
        )
        try await git.ensureRepository()
        try "user work".write(
            toFile: root + "/notes/unrelated.md",
            atomically: true,
            encoding: .utf8
        )
        _ = try runGit(["add", "--", "notes/unrelated.md"], at: root)
        try FileManager.default.removeItem(atPath: root + "/notes/deleted.md")

        try await git.commitDeletion(
            path: "notes/deleted.md",
            message: "scoped deletion"
        )

        #expect(try runGit(["diff", "--cached", "--name-only"], at: root)
            .contains("notes/unrelated.md"))
        #expect(try !runGit(
            ["show", "--pretty=format:", "--name-only", "HEAD"],
            at: root
        ).contains("notes/unrelated.md"))
    }

    @Test("Mutation recovery marker requires the request fingerprint")
    func mutationCommitLookupRejectsSpoofedIdentifierOnlyMarker() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        let path = "notes/marker.md"
        let identifier = MutationID()
        let fingerprint = MutationRequestFingerprint(rawValue: "exact-request")
        try "one".write(
            toFile: root + "/\(path)",
            atomically: true,
            encoding: .utf8
        )
        try await commitCurrentMarkdown(
            git,
            root: root,
            path: path,
            message: "[mutation \(identifier.rawValue)]"
        )

        #expect(try await !git.containsMutationCommit(
            identifier: identifier,
            fingerprint: fingerprint
        ))

        try "two".write(
            toFile: root + "/\(path)",
            atomically: true,
            encoding: .utf8
        )
        try await commitCurrentMarkdown(
            git,
            root: root,
            path: path,
            message: "exact identity",
            identity: GitMutationIdentity(
                identifier: identifier,
                fingerprint: fingerprint
            )
        )
        #expect(try await git.containsMutationCommit(
            identifier: identifier,
            fingerprint: fingerprint
        ))
    }

    @Test("Path text cannot spoof the terminal mutation identity")
    func pathMarkersCannotSpoofRecoveryIdentity() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        let target = GitMutationIdentity(
            identifier: MutationID(
                rawValue: "11111111-1111-1111-1111-111111111111"
            )!,
            fingerprint: MutationRequestFingerprint(
                rawValue: String(repeating: "a", count: 64)
            )
        )
        let attacker = GitMutationIdentity(
            identifier: MutationID(
                rawValue: "22222222-2222-2222-2222-222222222222"
            )!,
            fingerprint: MutationRequestFingerprint(
                rawValue: String(repeating: "b", count: 64)
            )
        )
        let path = "notes/spoof-[mutation \(target.identifier.rawValue)]-"
            + "[request \(target.fingerprint.rawValue)].md"
        try "spoof".write(
            toFile: root + "/" + path,
            atomically: true,
            encoding: .utf8
        )
        try await commitCurrentMarkdown(
            git,
            root: root,
            path: path,
            message: "[SecondBrainMCP] Created markdown: \(path)",
            identity: attacker
        )

        #expect(try await !git.containsMutationCommit(
            identifier: target.identifier,
            fingerprint: target.fingerprint
        ))
        #expect(try await git.containsMutationCommit(
            identifier: attacker.identifier,
            fingerprint: attacker.fingerprint
        ))
    }

    @Test("Managed CRUD commits normalize executable files to regular Git mode")
    func fileCommitNormalizesExecutableMode() async throws {
        let (root, initialGit) = try makeRepository()
        try await initialGit.ensureRepository()
        let path = "notes/mode.md"
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        let data = Data("mode-safe".utf8)
        try data.write(to: url)
        #expect(Darwin.chmod(url.path, 0o644) == 0)
        let git = GitRepository(repoPath: root) {
            guard Darwin.chmod(url.path, 0o755) == 0 else {
                throw GitTestError.commandFailed
            }
        }

        try await git.commitChange(
            file: path,
            expectedRevision: FileSnapshot(data: data, modifiedDate: nil).revision,
            maximumBytes: FileFormat.markdown.maximumFileBytes,
            message: "normalize mode"
        )

        let tree = try runGit(["ls-tree", "HEAD", "--", path], at: root)
        #expect(tree.hasPrefix("100644 blob "))
        var metadata = stat()
        #expect(Darwin.lstat(url.path, &metadata) == 0)
        #expect(metadata.st_mode & S_IXUSR != 0)
    }

    @Test("Move index validation accepts valid manifests larger than one MiB")
    func moveManifestOutputAboveLegacyCaptureLimit() throws {
        let rootPath = "notes/completed/ticket"
        let blobID = String(repeating: "a", count: 40)
        var entries: [String: DirectoryMoveSecurityPreflight.Manifest.Entry] = [:]
        var output = Data()
        var aggregatePathBytes = 0
        for index in 0..<6_000 {
            let path = rootPath + "/" + String(format: "%05d-", index)
                + String(repeating: "p", count: 120) + ".md"
            aggregatePathBytes += path.utf8.count
            entries[path] = DirectoryMoveSecurityPreflight.Manifest.Entry(
                byteCount: 1,
                sha256: String(repeating: "b", count: 64),
                gitSHA1: blobID,
                gitSHA256: String(repeating: "c", count: 64),
                gitMode: "100644"
            )
            output.append(Data("100644 \(blobID) 0\t\(path)\0".utf8))
        }
        let manifest = DirectoryMoveSecurityPreflight.Manifest(
            rootPath: rootPath,
            entries: entries,
            summary: .init(
                digest: String(repeating: "d", count: 64),
                entryCount: entries.count,
                totalBytes: entries.count
            ),
            aggregatePathBytes: aggregatePathBytes
        )
        let maximum = try GitRepository.maximumMoveIndexOutputBytes(
            manifest: manifest,
            objectFormat: "sha1",
            destinationPath: rootPath
        )

        #expect(output.count > 1_024 * 1_024)
        #expect(output.count == maximum)
        try GitRepository.validateMoveIndexOutput(
            output,
            maximumOutputBytes: maximum,
            destinationPath: rootPath,
            manifest: manifest,
            objectFormat: "sha1"
        )
        #expect(throws: GitRepository.UnsafeStartupSnapshot.self) {
            try GitRepository.validateMoveIndexOutput(
                output + Data([0]),
                maximumOutputBytes: maximum,
                destinationPath: rootPath,
                manifest: manifest,
                objectFormat: "sha1"
            )
        }
    }

    @Test("A directory move force-tracks files ignored at the destination")
    func moveCommitOverridesAncestorIgnore() async throws {
        let (root, git) = try makeRepository()
        try FileManager.default.createDirectory(
            atPath: root + "/notes/source/ticket",
            withIntermediateDirectories: true
        )
        try "tracked".write(
            toFile: root + "/notes/source/ticket/note.md",
            atomically: true,
            encoding: .utf8
        )
        try await git.ensureRepository()
        try "notes/completed/**\n".write(
            toFile: root + "/.gitignore",
            atomically: true,
            encoding: .utf8
        )
        _ = try runGit(["add", ".gitignore"], at: root)
        _ = try runGit(["commit", "-m", "ignore destination"], at: root)
        try FileManager.default.createDirectory(
            atPath: root + "/notes/completed",
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            atPath: root + "/notes/source/ticket",
            toPath: root + "/notes/completed/ticket"
        )

        try await git.commitMove(
            sourcePath: "notes/source/ticket",
            destinationPath: "notes/completed/ticket",
            message: "move ignored destination"
        )

        #expect(try runGit(
            ["ls-tree", "-r", "--name-only", "HEAD", "--", "notes/completed"],
            at: root
        ).contains("notes/completed/ticket/note.md"))
        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
    }

    @Test("Post-validation worktree changes cannot alter the move commit")
    func moveCommitUsesValidatedImmutableTree() async throws {
        let (root, initialGit) = try makeRepository()
        try FileManager.default.createDirectory(
            atPath: root + "/notes/source/ticket",
            withIntermediateDirectories: true
        )
        try "safe".write(
            toFile: root + "/notes/source/ticket/note.md",
            atomically: true,
            encoding: .utf8
        )
        try await initialGit.ensureRepository()
        try FileManager.default.createDirectory(
            atPath: root + "/notes/completed",
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            atPath: root + "/notes/source/ticket",
            toPath: root + "/notes/completed/ticket"
        )
        let destination = root + "/notes/completed/ticket/note.md"
        let git = GitRepository(repoPath: root) {
            try "api_key=abcdefghijklmnop1234567890".write(
                toFile: destination,
                atomically: true,
                encoding: .utf8
            )
        }

        try await git.commitMove(
            sourcePath: "notes/source/ticket",
            destinationPath: "notes/completed/ticket",
            message: "immutable move"
        )

        #expect(try runGit(
            ["show", "HEAD:notes/completed/ticket/note.md"],
            at: root
        ).trimmingCharacters(in: .whitespacesAndNewlines) == "safe")
        #expect(try String(contentsOfFile: destination, encoding: .utf8)
            .contains("api_key="))
        #expect(try runGit(["status", "--porcelain"], at: root)
            .contains("notes/completed/ticket/note.md"))
    }

    @Test("Snapshots external changes on startup")
    func snapshotsDirtyRepository() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        try "external".write(toFile: root + "/notes/external.md", atomically: true, encoding: .utf8)

        try await git.ensureRepository()

        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
        #expect(try runGit(["rev-list", "--count", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    @Test("Startup commits only its immutable validated tree and bypasses hooks")
    func startupSnapshotIsImmutableAndPreservesConcurrentStaging() async throws {
        let (root, initialGit) = try makeRepository()
        try "original".write(
            toFile: root + "/notes/unrelated.md",
            atomically: true,
            encoding: .utf8
        )
        try await initialGit.ensureRepository()
        try "validated".write(
            toFile: root + "/notes/startup.md",
            atomically: true,
            encoding: .utf8
        )
        let hook = root + "/.git/hooks/pre-commit"
        try """
        #!/bin/sh
        printf invoked > .git/hook-was-invoked
        printf 'api_key=abcdefghijklmnop1234567890' > notes/startup.md
        /usr/bin/git add -- notes/startup.md
        exit 0
        """.write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hook
        )
        let git = GitRepository(
            repoPath: root,
            startupIndexValidatedObserver: {
                try "concurrently staged".write(
                    toFile: root + "/notes/unrelated.md",
                    atomically: true,
                    encoding: .utf8
                )
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["add", "--", "notes/unrelated.md"]
                process.currentDirectoryURL = URL(fileURLWithPath: root)
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw GitTestError.commandFailed
                }
            }
        )

        try await git.ensureRepository()

        #expect(try runGit(["show", "HEAD:notes/startup.md"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "validated")
        #expect(try runGit(["show", "HEAD:notes/unrelated.md"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "original")
        #expect(try runGit(["diff", "--cached", "--name-only"], at: root)
            .contains("notes/unrelated.md"))
        #expect(!FileManager.default.fileExists(
            atPath: root + "/.git/hook-was-invoked"
        ))
    }

    @Test("Temporary Git index cleanup ignores links and removes old owned artifacts")
    func temporaryIndexScavengingIsConservative() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitIndexScavengeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent(
            GitTemporaryIndexWorkspace.directoryPrefix + UUID().uuidString
        )
        try FileManager.default.createDirectory(
            at: stale,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: stale.path
        )
        let victim = root.appendingPathComponent("victim")
        try FileManager.default.createDirectory(
            at: victim,
            withIntermediateDirectories: false
        )
        let link = root.appendingPathComponent(
            GitTemporaryIndexWorkspace.directoryPrefix + UUID().uuidString
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

        let live = try GitTemporaryIndexWorkspace.scavengeStaleArtifacts(
            in: root,
            now: Date(),
            staleAge: 1
        )

        #expect(live == 0)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: victim.path))
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test("Repository tree and materialized index ceilings fail closed")
    func repositoryIndexBoundsRejectOversizedInputs() throws {
        let overEntryLimit = Data(
            repeating: 0,
            count: GitTemporaryIndexWorkspace.maximumTreeEntries + 1
        )
        #expect(throws: GitRepository.UnsafeStartupSnapshot.self) {
            try GitTemporaryIndexWorkspace.validateTreeListing(
                overEntryLimit,
                path: "tree"
            )
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitIndexSizeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("index")
        try Data().write(to: index)
        #expect(Darwin.truncate(
            index.path,
            off_t(GitTemporaryIndexWorkspace.maximumIndexBytes + 1)
        ) == 0)
        let workspace = GitTemporaryIndexWorkspace(directory: root, file: index)
        #expect(throws: GitRepository.UnsafeStartupSnapshot.self) {
            try workspace.validateMaterializedIndex()
        }
    }

    @Test("Candidate index ceiling is enforced after write-tree and before commit")
    func candidateIndexCeilingRefusesBeforeCommitWithoutWedging() async throws {
        let (root, initialGit) = try makeRepository()
        try await initialGit.ensureRepository()
        let originalHead = try runGit(["rev-parse", "HEAD"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = "notes/candidate.md"
        try "bounded candidate".write(
            toFile: root + "/" + path,
            atomically: true,
            encoding: .utf8
        )
        let observedGit = GitRepository(
            repoPath: root,
            isolatedCandidateTreeObserver: { index in
                guard Darwin.truncate(
                    index.path,
                    off_t(GitTemporaryIndexWorkspace.maximumIndexBytes + 1)
                ) == 0 else {
                    throw GitTestError.commandFailed
                }
            }
        )

        await #expect(throws: GitRepository.UnsafeStartupSnapshot.self) {
            try await commitCurrentMarkdown(
                observedGit,
                root: root,
                path: path,
                message: "refused oversized candidate"
            )
        }
        #expect(
            try runGit(["rev-parse", "HEAD"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == originalHead
        )

        let retryGit = GitRepository(repoPath: root)
        try await commitCurrentMarkdown(
            retryGit,
            root: root,
            path: path,
            message: "bounded retry"
        )
        #expect(
            try runGit(["show", "HEAD:" + path], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "bounded candidate"
        )
    }

    @Test("Large startup snapshots parse one bounded index manifest")
    func startupUsesOneIndexManifestForManyFiles() async throws {
        let (root, initialGit) = try makeRepository()
        try await initialGit.ensureRepository()
        try "*.md text eol=lf\n".write(
            toFile: root + "/.gitattributes",
            atomically: true,
            encoding: .utf8
        )
        for index in 0..<512 {
            try Data("note \(index)\r\n".utf8).write(
                to: URL(
                    fileURLWithPath: root + "/notes/manifest-\(index).md"
                )
            )
        }
        let commands = GitCommandRecorder()
        let git = GitRepository(
            repoPath: root,
            commandRunner: GitCommandRunner { arguments in
                commands.record(arguments)
            }
        )

        try await git.ensureRepository()

        let observed = commands.values()
        #expect(observed.filter { $0 == ["ls-files", "-s", "-z"] }.count == 1)
        #expect(!observed.contains { arguments in
            arguments.contains("ls-files")
                && arguments.contains("-s")
                && arguments.contains("--")
        })
        #expect(observed.filter {
            $0.first == "cat-file"
                && $0.dropFirst().first?.hasPrefix("--batch-check=") == true
        }.count == 1)
        #expect(observed.filter {
            $0.first == "cat-file"
                && $0.dropFirst().first?.hasPrefix("--batch=") == true
        }.count == 1)
        #expect(!observed.contains { $0.prefix(2) == ["cat-file", "blob"] })
        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
    }

    @Test("Initial startup refuses to commit credential-bearing vault text")
    func initialSnapshotRejectsSecrets() async throws {
        let (root, git) = try makeRepository()
        let secret = "Bearer " + String(repeating: "s", count: 32)
        try secret.write(
            toFile: root + "/notes/external.md",
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: GitRepository.UnsafeStartupSnapshot.self) {
            try await git.ensureRepository()
        }

        #expect(
            try gitExitStatus(["rev-parse", "--verify", "HEAD"], at: root) != 0
        )
        #expect(
            try runGit(["status", "--porcelain"], at: root)
                .contains("?? notes/")
        )
    }

    @Test("Dirty startup refuses escaped JSON credentials without changing HEAD")
    func dirtySnapshotRejectsEscapedJSONSecrets() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        let originalHead = try runGit(["rev-parse", "HEAD"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = String(repeating: "t", count: 32)
        let content = #"{"access\u005ftoken":""# + secret + #""}"#
        try content.write(
            toFile: root + "/notes/external.json",
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: GitRepository.UnsafeStartupSnapshot.self) {
            try await git.ensureRepository()
        }

        #expect(
            try runGit(["rev-parse", "HEAD"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == originalHead
        )
        #expect(
            try runGit(["status", "--porcelain"], at: root)
                .contains("?? notes/")
        )
    }

    @Test(
        "Startup scans credential-bearing text outside supported extensions",
        arguments: [".env", "settings.yaml", "instructions.txt"]
    )
    func startupRejectsUnknownTextFormats(_ name: String) async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        let originalHead = try runGit(["rev-parse", "HEAD"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = "Authorization: Bearer "
            + String(repeating: "u", count: 32)
        try secret.write(
            toFile: root + "/" + name,
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: GitRepository.UnsafeStartupSnapshot.self) {
            try await git.ensureRepository()
        }

        #expect(
            try runGit(["rev-parse", "HEAD"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == originalHead
        )
        #expect(
            try runGit(["status", "--porcelain", "--untracked-files=all"], at: root)
                .contains(name)
        )
    }

    @Test("Text-oriented unknown files cannot become binary through invalid encoding")
    func startupRejectsInvalidTextEncoding() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        var data = Data(
            ("Bearer " + String(repeating: "v", count: 32)).utf8
        )
        data.append(0xff)
        try data.write(to: URL(fileURLWithPath: root + "/.env"))

        await #expect(throws: GitRepository.UnsafeStartupSnapshot.self) {
            try await git.ensureRepository()
        }

        #expect(
            try runGit(["status", "--porcelain", "--untracked-files=all"], at: root)
                .contains(".env")
        )
    }

    @Test("Startup validates Git-normalized staged bytes")
    func startupValidatesNormalizedStagedBlob() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        try "*.txt text eol=lf\n".write(
            toFile: root + "/.gitattributes",
            atomically: true,
            encoding: .utf8
        )
        try Data("safe\r\ncontent\r\n".utf8).write(
            to: URL(fileURLWithPath: root + "/notes/normalized.txt")
        )

        try await git.ensureRepository()

        let committed = try runGit(
            ["show", "HEAD:notes/normalized.txt"],
            at: root
        )
        #expect(committed == "safe\ncontent\n")
        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
    }

    @Test("Sanitizes commit messages")
    func sanitizesMessage() {
        let dirty = "message\n$(touch /tmp/nope); `bad` & more"
        let clean = GitRepository.sanitizeCommitMessage(dirty)
        #expect(!clean.contains("$"))
        #expect(!clean.contains(";"))
        #expect(!clean.contains("`"))
        #expect(!clean.contains("&"))
        #expect(!clean.contains("\n"))
    }

    private enum GitTestError: Error {
        case commandFailed
    }
}

private final class GitCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []

    func record(_ arguments: [String]) {
        lock.lock()
        commands.append(arguments)
        lock.unlock()
    }

    func values() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }
}
