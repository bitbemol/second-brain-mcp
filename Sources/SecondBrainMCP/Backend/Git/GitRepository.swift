import CryptoKit
import Foundation

/// Serializes the Git mutations required by generic file CRUD.
actor GitRepository {
    private struct StartupSnapshotValidation: Sendable {
        struct File: Sendable {
            let expectedBlobID: String
            let format: FileFormat?
            let maximumBytes: Int
        }

        let paths: Set<String>
        let files: [String: File]
    }

    /// Existing external changes failed the same policy used by managed writes.
    struct UnsafeStartupSnapshot: Error, CustomStringConvertible, Sendable {
        let path: String

        var description: String {
            "Startup snapshot refused because \(path) did not pass the vault security policy"
        }
    }

    private let repoPath: String
    private let commandRunner: GitCommandRunner

    /// Creates a repository adapter for a vault Git working tree.
    ///
    /// - Parameters:
    ///   - repoPath: Absolute path to the vault Git working tree.
    ///   - commandRunner: Low-level Git process adapter.
    init(repoPath: String, commandRunner: GitCommandRunner = GitCommandRunner()) {
        self.repoPath = repoPath
        self.commandRunner = commandRunner
    }

    /// Initialize a repository or snapshot external changes before serving.
    func ensureRepository() async throws {
        if FileManager.default.fileExists(atPath: repoPath + "/.git") {
            try await installManagedExclusions()
            try await ensureCommitIdentity()
            try await snapshotIfDirty()
        } else {
            try await initializeRepository()
        }
    }

    /// Stages only the supplied paths and commits them with a sanitized message.
    ///
    /// - Parameters:
    ///   - files: Vault-relative files produced by one CRUD mutation.
    ///   - message: Human-readable commit message; unsupported characters and
    ///     newlines are removed before invoking Git.
    func commitChange(files: [String], message: String) async throws {
        guard !files.isEmpty else { return }
        for file in files {
            try await run(["--literal-pathspecs", "add", "--", file])
        }
        try await run(
            ["--literal-pathspecs", "commit", "--only", "-m",
             Self.sanitizeCommitMessage(message), "--"]
                + files
        )
    }

    /// Records a soft deletion without staging unrelated changes.
    ///
    /// `git add -A` is scoped to the exact deleted path so edits to sibling files
    /// remain outside the operation's commit.
    func commitDeletion(path: String, message: String) async throws {
        try await run(["--literal-pathspecs", "add", "-A", "--", path])
        try await run([
            "--literal-pathspecs", "commit", "--only", "-m",
            Self.sanitizeCommitMessage(message),
            "--", path
        ])
    }

    /// Stages both sides of one directory rename and commits only that subtree move.
    func commitMove(
        sourcePath: String,
        destinationPath: String,
        message: String
    ) async throws {
        // The source no longer exists in the worktree. `git rm --cached` is
        // replay-safe even after a previous failed commit already staged the
        // deletion; destination staging then captures every moved descendant.
        try await run([
            "--literal-pathspecs", "rm", "-r", "--cached", "--ignore-unmatch",
            "--", sourcePath
        ])
        try await run([
            "--literal-pathspecs", "add", "-A", "--", destinationPath
        ])
        let destination = try NotesDirectoryTarget.resolve(
            path: destinationPath,
            vaultPath: repoPath
        )
        try DirectoryMoveSecurityPreflight.validate(destination)
        // The staged bytes must still equal the just-validated worktree. This
        // prevents a concurrent external edit from entering the commit between
        // validation and the path-scoped commit.
        try await run([
            "--literal-pathspecs", "diff", "--quiet", "--", destinationPath
        ])
        try await run([
            "--literal-pathspecs", "commit", "--only", "-m",
            Self.sanitizeCommitMessage(message),
            "--", sourcePath, destinationPath
        ])
    }

    /// Reports whether a mutation-aware commit touches the supplied destination.
    func containsMutationCommit(
        identifier: MutationID,
        paths: [String]
    ) async throws -> Bool {
        let output = try await run([
            "--literal-pathspecs",
            "log",
            "--fixed-strings",
            "--grep=[mutation \(identifier.rawValue)]",
            "--format=%H",
            "--"
        ] + paths)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Reports whether Git already contains the uniquely identified mutation.
    ///
    /// Commit-only recovery calls this before creating a commit so a crash after
    /// Git succeeded but before receipt finalization cannot create or require a
    /// second commit.
    func containsMutationCommit(
        identifier: MutationID,
        path: String
    ) async throws -> Bool {
        let output = try await run([
            "--literal-pathspecs",
            "log",
            "--fixed-strings",
            "--grep=[mutation \(identifier.rawValue)]",
            "--format=%H",
            "--",
            path
        ])
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Converts untrusted operation text into a single-line Git commit message.
    static func sanitizeCommitMessage(_ message: String) -> String {
        message
            .replacingOccurrences(of: "\n", with: " ")
            .filter { character in
                character.isLetter
                    || character.isNumber
                    || character.isWhitespace
                    || "-_./[]():,".contains(character)
            }
    }

    private func initializeRepository() async throws {
        try await run(["init"])
        try await installManagedExclusions()
        try await ensureCommitIdentity()
        let validation = try await validateStartupSnapshot()
        try await stageAndValidateStartupSnapshot(validation)
        try await run([
            "commit", "--allow-empty", "-m",
            "[SecondBrainMCP] Initial commit of existing vault"
        ])
    }

    private func snapshotIfDirty() async throws {
        guard try await isDirty() else { return }
        let validation = try await validateStartupSnapshot()
        try await stageAndValidateStartupSnapshot(validation)
        try await run(["commit", "-m", "[SecondBrainMCP] Snapshot of uncommitted changes on startup"])
    }

    private func isDirty() async throws -> Bool {
        let output = try await run(["status", "--porcelain"])
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Broadly stages the snapshot, verifies its exact blob identities, and
    /// restores the prior index tree if post-stage verification refuses it.
    private func stageAndValidateStartupSnapshot(
        _ validation: StartupSnapshotValidation
    ) async throws {
        let originalIndexTree = try await run(["write-tree"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await run(["--literal-pathspecs", "add", "."])
            try await validateStagedStartupSnapshot(validation)
        } catch {
            // Restore only the index. The user's working files are never changed.
            _ = try? await run(["read-tree", originalIndexTree])
            throw error
        }
    }

    /// Scans changed and untracked files before broad startup adds.
    ///
    /// Normal CRUD commits are path-scoped and validate prepared bytes. Startup
    /// intentionally snapshots external edits with `git add .`, so it must first
    /// recover that security boundary for every file Git is about to include.
    private func validateStartupSnapshot() async throws -> StartupSnapshotValidation {
        let paths = try await startupCandidatePaths(includeWorktree: true)
        var files: [String: StartupSnapshotValidation.File] = [:]

        for path in paths.sorted() {
            do {
                guard !PathValidator.containsSymbolicLinkComponent(
                    relativePath: path,
                    root: repoPath
                ) else {
                    continue
                }
                let resolved = try PathValidator.resolve(
                    relativePath: path,
                    root: repoPath
                )
                let url = URL(fileURLWithPath: resolved)
                guard FileManager.default.fileExists(atPath: resolved) else {
                    continue
                }
                let metadata = try RegularFileInspector.inspect(url)
                let format = FileFormat.allCases.first { $0.accepts(path: path) }
                // Broad startup snapshots can encounter formats outside the
                // public API. Bound those and binary candidates to the largest
                // Git-tracked text tier instead of allowing opaque huge blobs.
                let startupLimit = min(
                    format?.maximumFileBytes ?? FileFormat.log.maximumFileBytes,
                    FileFormat.log.maximumFileBytes
                )
                guard metadata.byteCount <= startupLimit else {
                    throw UnsafeStartupSnapshot(path: path)
                }
                let data = try BoundedFileReader.read(
                    from: url,
                    maximumBytes: startupLimit,
                    path: path
                )
                try Self.validateStartupData(data, format: format, path: path)
                files[path] = StartupSnapshotValidation.File(
                    expectedBlobID: Self.gitBlobID(for: data),
                    format: format,
                    maximumBytes: startupLimit
                )
            } catch {
                throw UnsafeStartupSnapshot(path: path)
            }
        }
        return StartupSnapshotValidation(
            paths: paths,
            files: files
        )
    }

    /// Confirms broad staging contains only candidates seen by preflight and
    /// that every scanned file's staged Git blob is byte-identical to it.
    private func validateStagedStartupSnapshot(
        _ validation: StartupSnapshotValidation
    ) async throws {
        let stagedPaths = try await startupCandidatePaths(includeWorktree: false)
        guard stagedPaths.isSubset(of: validation.paths) else {
            throw UnsafeStartupSnapshot(path: "files changed during startup")
        }
        for (path, file) in validation.files {
            guard stagedPaths.contains(path) else { continue }
            let output = try await run([
                "--literal-pathspecs", "ls-files", "-s", "--", path,
            ])
            let fields = output.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 3, fields[2] == "0" else {
                throw UnsafeStartupSnapshot(path: path)
            }
            let stagedBlobID = String(fields[1])
            guard stagedBlobID != file.expectedBlobID else { continue }

            // Git attributes may deliberately normalize the staged bytes. Read
            // and validate that immutable blob instead of either rejecting safe
            // transformations or trusting bytes that were never inspected.
            let staged = try await commandRunner.runData(
                ["cat-file", "blob", stagedBlobID],
                in: URL(fileURLWithPath: repoPath, isDirectory: true),
                maximumCapturedBytes: file.maximumBytes + 1
            )
            guard staged.count <= file.maximumBytes else {
                throw UnsafeStartupSnapshot(path: path)
            }
            do {
                try Self.validateStartupData(
                    staged,
                    format: file.format,
                    path: path
                )
            } catch {
                throw UnsafeStartupSnapshot(path: path)
            }
        }
    }

    private func startupCandidatePaths(
        includeWorktree: Bool
    ) async throws -> Set<String> {
        let commands = [
            ["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMRTUXB"],
        ] + (includeWorktree ? [
            ["diff", "--name-only", "-z", "--diff-filter=ACMRTUXB"],
            ["ls-files", "--others", "--exclude-standard", "-z"],
        ] : [])
        var paths = Set<String>()
        for command in commands {
            let output = try await run(command)
            // GitCommandRunner deliberately caps captured output. Refuse a broad
            // add when the candidate list may have been truncated.
            guard output.utf8.count < GitCommandRunner.maximumCapturedBytes else {
                throw UnsafeStartupSnapshot(path: "changed file list")
            }
            paths.formUnion(output.split(separator: "\0").map(String.init))
        }
        return paths
    }

    private static func gitBlobID(for data: Data) -> String {
        var object = Data("blob \(data.count)\0".utf8)
        object.append(data)
        return Insecure.SHA1.hash(data: object)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func validateStartupData(
        _ data: Data,
        format: FileFormat?,
        path: String
    ) throws {
        if let format, format.isTextual {
            try PersistedFileSecurityPolicy.validate(
                data,
                format: format,
                path: path
            )
        } else if String(data: data, encoding: .utf8) != nil {
            // Unknown extensions and extensionless files may still be ordinary
            // text such as .env, YAML, shell, or configuration.
            try SensitiveContentPolicy.validate(
                data,
                format: .log,
                path: path
            )
        } else if isTextOrientedUnknownPath(path) {
            // A stray invalid byte or UTF-16 encoding must not let an obvious
            // text/configuration file silently switch to the binary exemption.
            throw TextFileSupport.TextError.invalidUTF8
        }
    }

    private static func isTextOrientedUnknownPath(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let fileExtension = (filename as NSString).pathExtension
        if fileExtension.isEmpty || filename.hasPrefix(".env") {
            return true
        }
        return [
            "bash", "conf", "config", "env", "fish", "ini", "js", "jsonl",
            "properties", "py", "rb", "sh", "toml", "ts", "txt", "xml",
            "yaml", "yml", "zsh",
        ].contains(fileExtension)
    }

    /// Supplies a repository-local automation identity only when none is configured.
    private func ensureCommitIdentity() async throws {
        let name = try? await run(["config", "--get", "user.name"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name?.isEmpty != false {
            try await run(["config", "user.name", "SecondBrainMCP"])
        }

        let email = try? await run(["config", "--get", "user.email"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if email?.isEmpty != false {
            try await run(["config", "user.email", "secondbrainmcp@localhost"])
        }
    }

    /// Installs process-owned ignore rules without modifying the user's `.gitignore`.
    private func installManagedExclusions() async throws {
        let content = """
        # SecondBrainMCP managed exclusions
        /.secondbrain-mcp/
        /.trash/

        # PDF reference library (large binary files — not suitable for git)
        /references/

        # macOS
        .DS_Store

        # Common editor files
        *.swp
        *~
        """
        let rawPath = try await run(["rev-parse", "--git-path", "info/exclude"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let excludeURL: URL
        if rawPath.hasPrefix("/") {
            excludeURL = URL(fileURLWithPath: rawPath)
        } else {
            excludeURL = URL(fileURLWithPath: repoPath, isDirectory: true)
                .appendingPathComponent(rawPath)
                .standardized
        }

        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        guard !existing.contains("# SecondBrainMCP managed exclusions") else {
            return
        }
        try FileManager.default.createDirectory(
            at: excludeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + separator + content + "\n").write(
            to: excludeURL,
            atomically: true,
            encoding: .utf8
        )
    }

    @discardableResult
    private func run(_ arguments: [String]) async throws -> String {
        try await commandRunner.run(
            arguments,
            in: URL(fileURLWithPath: repoPath, isDirectory: true)
        )
    }
}
