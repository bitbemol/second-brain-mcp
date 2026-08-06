import Foundation

/// Serializes the Git mutations required by generic file CRUD.
actor GitRepository {
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
        try await run(["--literal-pathspecs", "add", "."])
        try await run([
            "commit", "--allow-empty", "-m",
            "[SecondBrainMCP] Initial commit of existing vault"
        ])
    }

    private func snapshotIfDirty() async throws {
        guard try await isDirty() else { return }
        try await run(["--literal-pathspecs", "add", "."])
        try await run(["commit", "-m", "[SecondBrainMCP] Snapshot of uncommitted changes on startup"])
    }

    private func isDirty() async throws -> Bool {
        let output = try await run(["status", "--porcelain"])
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
