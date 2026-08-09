//
//  GitRepositoryV2.swift
//  SecondBrainMCP
//
//  Created by BitBemol on 09/08/26.
//

import Foundation
import Subprocess

/// Records recoverable snapshots of the vault's notes in a local Git repository.
///
/// A snapshot represents a useful vault state, not one agent's activity. When
/// several agents modify notes concurrently, one commit may therefore contain
/// all of their changes. A later request that finds nothing new is successful
/// because the requested state has already been recorded.
///
/// The versioning lock serializes Git operations; it intentionally does not stop
/// agents from writing notes. A change that becomes visible before `git add`
/// stages its file may be included in the snapshot currently in progress, even
/// when another agent initiated that snapshot. A change that arrives after its
/// file was staged remains in the working tree and is captured by the next
/// snapshot request. This is deliberate: commits are vault recovery points, not
/// ownership records for individual agents or mutations.
///
/// The temporary V2 name lets this replacement coexist with the legacy
/// ``GitRepository`` until its callers have migrated to ``VaultVersioning``.
actor GitRepositoryV2: VaultVersioning {
    /// A deliberately generic subject because commits describe vault states,
    /// not individual mutations or authors.
    private static let snapshotMessage = "Vault snapshot"

    /// Bounds retained diagnostics so a failing child process cannot grow
    /// application memory without limit.
    private static let maximumErrorBytes = 32 * 1024

    /// Removes inherited Git control variables that could redirect a command
    /// away from `repositoryURL`, while preserving the normal process context.
    private static let gitEnvironment: Environment = {
        var values: [Environment.Key: String] = [:]

        for (key, value) in ProcessInfo.processInfo.environment
        where !key.hasPrefix("GIT_") {
            guard let environmentKey = Environment.Key(rawValue: key) else {
                continue
            }
            values[environmentKey] = value
        }

        values["GIT_TERMINAL_PROMPT"] = "0"
        values["GIT_PAGER"] = "cat"
        return .custom(values)
    }()

    private let repositoryURL: URL
    private let versioningLock: POSIXAdvisoryFileLock

    /// Creates a Git-backed vault versioner.
    ///
    /// Every actor instance and MCP process operating on the same vault must
    /// receive the same `lockURL`. The lock's parent directory must already
    /// exist. The lock is intentionally separate from Git's `.git/index.lock`:
    /// Git owns that file, while this lock coordinates our complete multi-command
    /// snapshot transaction.
    ///
    /// - Parameters:
    ///   - repositoryURL: The vault directory that Git should initialize or use.
    ///   - lockURL: A stable application-owned lock file shared by every process
    ///     operating on this vault.
    /// - Throws: ``VaultVersioningError`` when either URL is not a file URL.
    init(repositoryURL: URL, lockURL: URL) throws {
        guard repositoryURL.isFileURL else {
            throw VaultVersioningError.invalidRepositoryURL
        }
        guard lockURL.isFileURL else {
            throw VaultVersioningError.invalidLockURL
        }

        self.repositoryURL = repositoryURL.standardizedFileURL
        self.versioningLock = POSIXAdvisoryFileLock(
            url: lockURL.standardizedFileURL
        )
    }

    /// Records the current notes state, or succeeds without committing when that
    /// state was already captured by another concurrent request.
    ///
    /// Swift actors are reentrant whenever an async method suspends. The
    /// application-owned advisory lock therefore covers the entire Git sequence,
    /// preventing overlapping `git add`, `git diff`, and `git commit` processes
    /// both locally and across MCP processes. It does not freeze the notes
    /// directory, so concurrent writes may join this snapshot according to what
    /// `git add` observes; that coalescing is part of the snapshot contract.
    func recordSnapshot() async throws {
        let versioningLock = self.versioningLock

        try await versioningLock.withLock(.exclusive) {
            try await self.performSnapshot()
        }
    }
}

private extension GitRepositoryV2 {
    /// The bounded information needed to interpret one completed Git process.
    struct GitResult {
        let status: TerminationStatus
        let standardError: String
    }

    /// Performs one exclusive initialize-stage-check-commit transaction.
    func performSnapshot() async throws {
        try await initializeRepositoryIfNeeded()
        try await stageNotesIfPresentOrTracked()

        let arguments = ["diff", "--cached", "--quiet"]
        let difference = try await executeGit(arguments)

        switch difference.status {
        case .exited(0):
            // A preceding agent may already have included this caller's changes.
            return

        case .exited(1):
            // Git uses exit 1 to report that staged differences exist.
            break

        default:
            throw commandFailure(arguments: arguments, result: difference)
        }

        try await requireSuccess([
            "-c", "user.name=SecondBrainMCP",
            "-c", "user.email=secondbrainmcp@localhost",
            "-c", "core.hooksPath=/dev/null",
            "commit",
            "--no-gpg-sign",
            "--message", Self.snapshotMessage,
        ])
    }

    /// Initializes Git only when the vault does not already contain repository
    /// metadata. This operation runs under the versioning lock so simultaneous
    /// first snapshots cannot race initialization.
    func initializeRepositoryIfNeeded() async throws {
        let gitMetadata = repositoryURL.appendingPathComponent(".git")

        guard !FileManager.default.fileExists(
            atPath: gitMetadata.path(percentEncoded: false)
        ) else {
            return
        }

        try await requireSuccess(["init"])
    }

    /// Stages creations, modifications, moves, and deletions below `notes/`.
    ///
    /// Git rejects an unmatched pathspec in a brand-new empty repository. We
    /// therefore distinguish an empty vault from deletion of all tracked notes;
    /// the former is already satisfied, while the latter must be staged.
    func stageNotesIfPresentOrTracked() async throws {
        let notesURL = repositoryURL.appendingPathComponent("notes")
        let notesExist = FileManager.default.fileExists(
            atPath: notesURL.path(percentEncoded: false)
        )

        if !notesExist {
            let arguments = [
                "ls-files",
                "--error-unmatch",
                "--",
                "notes",
            ]
            let trackedNotes = try await executeGit(arguments)

            switch trackedNotes.status {
            case .exited(0):
                // The directory was deleted, so stage its tracked deletions.
                break

            case .exited(1):
                // A new empty vault has no notes path and nothing to stage.
                return

            default:
                throw commandFailure(
                    arguments: arguments,
                    result: trackedNotes
                )
            }
        }

        try await requireSuccess([
            "add",
            "--all",
            "--",
            "notes",
        ])
    }

    /// Executes `/usr/bin/git` against the vault without invoking a shell.
    ///
    /// Git's `-C` option provides the repository directory while keeping the
    /// application-facing path type as Foundation's `URL`. Standard output is
    /// irrelevant to snapshot creation and discarded; bounded standard error is
    /// retained for actionable failures.
    func executeGit(_ arguments: [String]) async throws -> GitResult {
        let repositoryPath = repositoryURL.path(percentEncoded: false)

        let result = try await Subprocess.run(
            .path("/usr/bin/git"),
            arguments: Arguments(["-C", repositoryPath] + arguments),
            environment: Self.gitEnvironment,
            output: .discarded,
            error: .string(limit: Self.maximumErrorBytes)
        )

        return GitResult(
            status: result.terminationStatus,
            standardError: result.standardError
        )
    }

    /// Runs a Git command whose only accepted outcome is successful termination.
    func requireSuccess(_ arguments: [String]) async throws {
        let result = try await executeGit(arguments)

        guard result.status.isSuccess else {
            throw commandFailure(arguments: arguments, result: result)
        }
    }

    /// Converts a failed process result into the module's stable error boundary.
    func commandFailure(
        arguments: [String],
        result: GitResult
    ) -> VaultVersioningError {
        .gitCommandFailed(
            arguments: arguments,
            status: result.status.description,
            message: result.standardError
        )
    }
}
