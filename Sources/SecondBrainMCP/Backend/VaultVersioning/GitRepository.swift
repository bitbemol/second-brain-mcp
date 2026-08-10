//
//  GitRepository.swift
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
/// The vault access coordinator serializes the complete mutation and snapshot
/// chain. Commits are recovery points for coherent vault states, not ownership
/// records for individual agents or mutations.
actor GitRepository: VaultVersioning {
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

    /// Creates the sole Git subprocess boundary for one validated vault.
    init(repositoryURL: URL) throws {
        guard repositoryURL.isFileURL else {
            throw VaultVersioningError.invalidRepositoryURL
        }
        self.repositoryURL = repositoryURL.standardizedFileURL
    }

    /// Records the current notes state, or succeeds without committing when that
    /// state was already captured by another concurrent request.
    ///
    /// Runs only while the caller holds the coordinator's mutation lease.
    func recordSnapshot() async throws {
        try await performSnapshot()
    }
}

private extension GitRepository {
    /// The bounded information needed to interpret one completed Git process.
    struct GitResult {
        let status: TerminationStatus
        let standardError: String
    }

    /// Performs one exclusive initialize-stage-check-commit transaction.
    ///
    /// The dirty check and commit are both path-scoped to `notes/`. Staging notes
    /// alone is insufficient because an unscoped `git commit` also consumes entries
    /// another Git client previously staged in the real index, including large
    /// read-only reference files. `--only` records the notes state while preserving
    /// every staged entry outside that tree for its owner.
    func performSnapshot() async throws {
        try await initializeRepositoryIfNeeded()
        try await stageNotesIfPresentOrTracked()

        let arguments = [
            "diff",
            "--cached",
            "--quiet",
            "--",
            "notes",
        ]
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
            "--only",
            "--message", Self.snapshotMessage,
            "--",
            "notes",
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
