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

        try await git.commitChange(
            files: ["notes/*.md"],
            message: "[SecondBrainMCP] Created markdown [mutation \(identifier.rawValue)]"
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
            path: "notes/*.md"
        )
        let foundSibling = try await git.containsMutationCommit(
            identifier: identifier,
            path: "notes/sibling.md"
        )
        #expect(foundLiteral)
        #expect(!foundSibling)
    }

    @Test("Commits a scoped file change")
    func commitsChange() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        try "content".write(toFile: root + "/notes/file.md", atomically: true, encoding: .utf8)

        try await git.commitChange(files: ["notes/file.md"], message: "[SecondBrainMCP] Created markdown")

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

        try await git.commitChange(
            files: ["notes/managed.md"],
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

    @Test("Snapshots external changes on startup")
    func snapshotsDirtyRepository() async throws {
        let (root, git) = try makeRepository()
        try await git.ensureRepository()
        try "external".write(toFile: root + "/notes/external.md", atomically: true, encoding: .utf8)

        try await git.ensureRepository()

        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
        #expect(try runGit(["rev-list", "--count", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines) == "2")
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
