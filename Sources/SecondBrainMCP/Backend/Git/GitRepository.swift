import CryptoKit
import Foundation

/// Serializes the Git mutations required by generic file CRUD.
actor GitRepository {
    private struct StartupSnapshotValidation: Sendable {
        struct File: Sendable {
            let expectedSHA1BlobID: String
            let expectedSHA256BlobID: String
            let format: FileFormat?
            let maximumBytes: Int

            func expectedBlobID(objectFormat: String) -> String? {
                switch objectFormat {
                case "sha1": expectedSHA1BlobID
                case "sha256": expectedSHA256BlobID
                default: nil
                }
            }
        }

        let paths: Set<String>
        let files: [String: File]
    }

    private struct FilteredStagedBlob: Sendable {
        let path: String
        let file: StartupSnapshotValidation.File
        let objectID: String
        let byteCount: Int
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
    private let isolatedIndexValidatedObserver: (@Sendable () throws -> Void)?
    private let isolatedCandidateTreeObserver: (@Sendable (URL) throws -> Void)?
    private let startupIndexValidatedObserver: (@Sendable () throws -> Void)?

    /// Creates a repository adapter for a vault Git working tree.
    ///
    /// - Parameters:
    ///   - repoPath: Absolute path to the vault Git working tree.
    ///   - commandRunner: Low-level Git process adapter.
    init(
        repoPath: String,
        commandRunner: GitCommandRunner = GitCommandRunner(),
        isolatedIndexValidatedObserver: (@Sendable () throws -> Void)? = nil,
        isolatedCandidateTreeObserver: (@Sendable (URL) throws -> Void)? = nil,
        startupIndexValidatedObserver: (@Sendable () throws -> Void)? = nil
    ) {
        self.repoPath = repoPath
        self.commandRunner = commandRunner
        self.isolatedIndexValidatedObserver = isolatedIndexValidatedObserver
        self.isolatedCandidateTreeObserver = isolatedCandidateTreeObserver
        self.startupIndexValidatedObserver = startupIndexValidatedObserver
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

    private var isolatedMutations: GitIsolatedMutationPolicy {
        GitIsolatedMutationPolicy(
            repoPath: repoPath,
            commandRunner: commandRunner,
            validatedObserver: isolatedIndexValidatedObserver,
            candidateTreeCreatedObserver: isolatedCandidateTreeObserver
        )
    }

    func commitChange(
        file: String,
        expectedRevision: FileRevision,
        maximumBytes: Int,
        message: String,
        identity: GitMutationIdentity? = nil
    ) async throws {
        try await isolatedMutations.commitChange(
            file: file,
            expectedRevision: expectedRevision,
            maximumBytes: maximumBytes,
            message: message,
            identity: identity
        )
    }

    func commitDeletion(
        path: String,
        message: String,
        identity: GitMutationIdentity? = nil
    ) async throws {
        try await isolatedMutations.commitDeletion(
            path: path,
            message: message,
            identity: identity
        )
    }

    func commitMove(
        sourcePath: String,
        destinationPath: String,
        manifest suppliedManifest: DirectoryMoveSecurityPreflight.Manifest? = nil,
        message: String,
        identity: GitMutationIdentity? = nil
    ) async throws {
        try await isolatedMutations.commitMove(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            manifest: suppliedManifest,
            message: message,
            identity: identity
        )
    }

    func reconcileCommittedMove(
        sourcePath: String,
        destinationPath: String
    ) async throws {
        try await isolatedMutations.reconcileCommittedMove(
            sourcePath: sourcePath,
            destinationPath: destinationPath
        )
    }

    func reconcileCommittedChange(path: String) async throws {
        try await isolatedMutations.reconcileCommittedChange(path: path)
    }

    func containsMutationCommit(
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint
    ) async throws -> Bool {
        try await isolatedMutations.containsMutationCommit(
            identifier: identifier,
            fingerprint: fingerprint
        )
    }

    static func maximumMoveIndexOutputBytes(
        manifest: DirectoryMoveSecurityPreflight.Manifest,
        objectFormat: String,
        destinationPath: String
    ) throws -> Int {
        try GitIsolatedMutationPolicy.maximumMoveIndexOutputBytes(
            manifest: manifest,
            objectFormat: objectFormat,
            destinationPath: destinationPath
        )
    }

    static func validateMoveIndexOutput(
        _ outputData: Data,
        maximumOutputBytes: Int,
        destinationPath: String,
        manifest: DirectoryMoveSecurityPreflight.Manifest,
        objectFormat: String
    ) throws {
        try GitIsolatedMutationPolicy.validateMoveIndexOutput(
            outputData,
            maximumOutputBytes: maximumOutputBytes,
            destinationPath: destinationPath,
            manifest: manifest,
            objectFormat: objectFormat
        )
    }

    /// Converts untrusted operation text into a single-line Git commit message.
    static func sanitizeCommitMessage(_ message: String) -> String {
        GitIsolatedMutationPolicy.sanitizeCommitMessage(message)
    }

    private func initializeRepository() async throws {
        try await run(["init"])
        try await installManagedExclusions()
        try await ensureCommitIdentity()
        let validation = try await validateStartupSnapshot()
        try await commitStartupSnapshot(
            validation,
            message: "[SecondBrainMCP] Initial commit of existing vault"
        )
    }

    private func snapshotIfDirty() async throws {
        guard try await isDirty() else { return }
        let validation = try await validateStartupSnapshot()
        try await commitStartupSnapshot(
            validation,
            message: "[SecondBrainMCP] Snapshot of uncommitted changes on startup"
        )
    }

    private func isDirty() async throws -> Bool {
        let output = try await run(["status", "--porcelain"])
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Broadly stages once, freezes that index as an immutable tree, validates
    /// the frozen tree through a private index, and advances HEAD with compare-
    /// and-swap. Hooks and post-validation changes to the real index therefore
    /// cannot alter the bytes selected for this automated startup commit.
    private func commitStartupSnapshot(
        _ validation: StartupSnapshotValidation,
        message: String
    ) async throws {
        let originalIndexTree = try await run(["write-tree"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let originalHead = try? await run(["rev-parse", "--verify", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidateTree: String?
        do {
            try await run(["--literal-pathspecs", "add", "."])
            let tree = try await run(["write-tree"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            candidateTree = tree
            try await validateTreeBounds(tree, displayPath: "startup Git tree")

            let workspace = try GitTemporaryIndexWorkspace.create()
            defer { workspace.remove() }
            try await run(["read-tree", tree], gitIndexFile: workspace.file)
            try workspace.validateMaterializedIndex()
            let objectFormat = try await run([
                "rev-parse", "--show-object-format",
            ]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard objectFormat == "sha1" || objectFormat == "sha256" else {
                throw UnsafeStartupSnapshot(path: "unsupported Git object format")
            }
            try await validateStagedStartupSnapshot(
                validation,
                index: workspace.file,
                objectFormat: objectFormat
            )
            try startupIndexValidatedObserver?()

            var commitArguments = ["commit-tree", tree]
            if let originalHead {
                commitArguments += ["-p", originalHead]
            }
            commitArguments += ["-m", message]
            let commit = try await run(commitArguments)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedHead = originalHead
                ?? String(repeating: "0", count: objectFormat == "sha256" ? 64 : 40)
            try await run(["update-ref", "HEAD", commit, expectedHead])
        } catch {
            // Restore the old index only when no concurrent staging changed the
            // candidate after it was frozen. Never overwrite another writer's
            // newer real-index state while rolling back a refused snapshot.
            let currentHead = try? await run([
                "rev-parse", "--verify", "HEAD",
            ]).trimmingCharacters(in: .whitespacesAndNewlines)
            if currentHead == originalHead,
               let candidateTree,
               let currentTree = try? await run(["write-tree"])
                .trimmingCharacters(in: .whitespacesAndNewlines),
               currentTree == candidateTree {
                _ = try? await run(["read-tree", originalIndexTree])
            }
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
                    expectedSHA1BlobID: Self.gitBlobID(
                        for: data,
                        objectFormat: "sha1"
                    ),
                    expectedSHA256BlobID: Self.gitBlobID(
                        for: data,
                        objectFormat: "sha256"
                    ),
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
        _ validation: StartupSnapshotValidation,
        index: URL,
        objectFormat: String
    ) async throws {
        let stagedPaths = try await startupCandidatePaths(
            includeWorktree: false,
            index: index
        )
        guard stagedPaths.isSubset(of: validation.paths) else {
            throw UnsafeStartupSnapshot(path: "files changed during startup")
        }
        let maximumManifestBytes = try GitTemporaryIndexWorkspace
            .maximumIndexManifestBytes(objectFormat: objectFormat)
        let manifestData = try await commandRunner.runData(
            ["ls-files", "-s", "-z"],
            in: URL(fileURLWithPath: repoPath, isDirectory: true),
            maximumCapturedBytes: maximumManifestBytes + 1,
            gitIndexFile: index
        )
        let manifest = try GitTemporaryIndexWorkspace.parseIndexManifest(
            manifestData,
            maximumBytes: maximumManifestBytes,
            objectFormat: objectFormat,
            displayPath: "startup Git index"
        )
        var filteredBlobs: [(String, StartupSnapshotValidation.File, String)] = []
        for path in stagedPaths.sorted() {
            guard let file = validation.files[path],
                  let entry = manifest[path],
                  entry.stage == "0",
                  entry.mode == "100644" || entry.mode == "100755" else {
                throw UnsafeStartupSnapshot(path: path)
            }
            let stagedBlobID = entry.objectID
            guard let expectedBlobID = file.expectedBlobID(
                objectFormat: objectFormat
            ) else {
                throw UnsafeStartupSnapshot(path: path)
            }
            guard stagedBlobID != expectedBlobID else { continue }
            filteredBlobs.append((path, file, stagedBlobID))
        }
        if !filteredBlobs.isEmpty {
            try await validateFilteredStagedBlobs(
                filteredBlobs,
                index: index,
                objectFormat: objectFormat
            )
        }
    }

    /// Reads the exceptional blobs changed by configured clean filters in
    /// bounded batches. Normal candidates require only the single index
    /// manifest above, while filtered bytes still receive the complete policy.
    private func validateFilteredStagedBlobs(
        _ candidates: [(String, StartupSnapshotValidation.File, String)],
        index: URL,
        objectFormat: String
    ) async throws {
        let repositoryURL = URL(fileURLWithPath: repoPath, isDirectory: true)
        let input = Data(
            candidates.map(\.2).joined(separator: "\n").appending("\n").utf8
        )
        let hashLength = objectFormat == "sha256" ? 64 : 40
        let (checkBytes, overflow) = candidates.count
            .multipliedReportingOverflow(by: hashLength + 1 + 4 + 1 + 20 + 1)
        guard !overflow else {
            throw UnsafeStartupSnapshot(path: "filtered Git blobs")
        }
        let check = try await commandRunner.runData(
            ["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
            in: repositoryURL,
            maximumCapturedBytes: checkBytes + 1,
            gitIndexFile: index,
            standardInput: input
        )
        guard check.count <= checkBytes,
              let checkText = String(data: check, encoding: .utf8) else {
            throw UnsafeStartupSnapshot(path: "filtered Git blobs")
        }
        let lines = checkText.split(separator: "\n")
        guard lines.count == candidates.count else {
            throw UnsafeStartupSnapshot(path: "filtered Git blobs")
        }
        var staged: [FilteredStagedBlob] = []
        staged.reserveCapacity(candidates.count)
        for (candidate, line) in zip(candidates, lines) {
            let fields = line.split(separator: " ")
            guard fields.count == 3,
                  fields[0] == candidate.2,
                  fields[1] == "blob",
                  let byteCount = Int(fields[2]),
                  byteCount >= 0,
                  byteCount <= candidate.1.maximumBytes else {
                throw UnsafeStartupSnapshot(path: candidate.0)
            }
            staged.append(FilteredStagedBlob(
                path: candidate.0,
                file: candidate.1,
                objectID: candidate.2,
                byteCount: byteCount
            ))
        }

        // Bound retained batch output independently of total changed files.
        let maximumBatchBytes = 64 * 1024 * 1024
        var batch: [FilteredStagedBlob] = []
        var batchBytes = 0
        for candidate in staged {
            let recordBytes = hashLength + 1 + 4 + 1
                + String(candidate.byteCount).utf8.count + 1
                + candidate.byteCount + 1
            if !batch.isEmpty, batchBytes + recordBytes > maximumBatchBytes {
                try await validateFilteredStagedBlobBatch(
                    batch,
                    expectedBytes: batchBytes,
                    index: index,
                    repositoryURL: repositoryURL
                )
                batch.removeAll(keepingCapacity: true)
                batchBytes = 0
            }
            guard recordBytes <= maximumBatchBytes else {
                throw UnsafeStartupSnapshot(path: candidate.path)
            }
            batch.append(candidate)
            batchBytes += recordBytes
        }
        if !batch.isEmpty {
            try await validateFilteredStagedBlobBatch(
                batch,
                expectedBytes: batchBytes,
                index: index,
                repositoryURL: repositoryURL
            )
        }
    }

    private func validateFilteredStagedBlobBatch(
        _ batch: [FilteredStagedBlob],
        expectedBytes: Int,
        index: URL,
        repositoryURL: URL
    ) async throws {
        let input = Data(
            batch.map(\.objectID).joined(separator: "\n").appending("\n").utf8
        )
        let output = try await commandRunner.runData(
            ["cat-file", "--batch=%(objectname) %(objecttype) %(objectsize)"],
            in: repositoryURL,
            maximumCapturedBytes: expectedBytes + 1,
            gitIndexFile: index,
            standardInput: input
        )
        guard output.count == expectedBytes else {
            throw UnsafeStartupSnapshot(path: "filtered Git blobs")
        }
        var cursor = output.startIndex
        for candidate in batch {
            guard let headerEnd = output[cursor...].firstIndex(of: 10),
                  let header = String(
                    data: output[cursor..<headerEnd],
                    encoding: .utf8
                  ) else {
                throw UnsafeStartupSnapshot(path: candidate.path)
            }
            let fields = header.split(separator: " ")
            guard fields.count == 3,
                  fields[0] == candidate.objectID,
                  fields[1] == "blob",
                  fields[2] == String(candidate.byteCount) else {
                throw UnsafeStartupSnapshot(path: candidate.path)
            }
            let dataStart = output.index(after: headerEnd)
            guard candidate.byteCount <= output.distance(
                from: dataStart,
                to: output.endIndex
            ) else {
                throw UnsafeStartupSnapshot(path: candidate.path)
            }
            let dataEnd = output.index(
                dataStart,
                offsetBy: candidate.byteCount
            )
            guard dataEnd < output.endIndex, output[dataEnd] == 10 else {
                throw UnsafeStartupSnapshot(path: candidate.path)
            }
            do {
                try Self.validateStartupData(
                    Data(output[dataStart..<dataEnd]),
                    format: candidate.file.format,
                    path: candidate.path
                )
            } catch {
                throw UnsafeStartupSnapshot(path: candidate.path)
            }
            cursor = output.index(after: dataEnd)
        }
        guard cursor == output.endIndex else {
            throw UnsafeStartupSnapshot(path: "filtered Git blobs")
        }
    }

    private func startupCandidatePaths(
        includeWorktree: Bool,
        index: URL? = nil
    ) async throws -> Set<String> {
        let commands = [
            ["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMRTUXB"],
        ] + (includeWorktree ? [
            ["diff", "--name-only", "-z", "--diff-filter=ACMRTUXB"],
            ["ls-files", "--others", "--exclude-standard", "-z"],
        ] : [])
        var paths = Set<String>()
        for command in commands {
            let output = try await run(command, gitIndexFile: index)
            // GitCommandRunner deliberately caps captured output. Refuse a broad
            // add when the candidate list may have been truncated.
            guard output.utf8.count < GitCommandRunner.maximumCapturedBytes else {
                throw UnsafeStartupSnapshot(path: "changed file list")
            }
            paths.formUnion(output.split(separator: "\0").map(String.init))
        }
        return paths
    }

    private static func gitBlobID(
        for data: Data,
        objectFormat: String
    ) -> String {
        var object = Data("blob \(data.count)\0".utf8)
        object.append(data)
        switch objectFormat {
        case "sha256":
            return SHA256.hash(data: object)
                .map { String(format: "%02x", $0) }
                .joined()
        default:
            return Insecure.SHA1.hash(data: object)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    private static func validateStartupData(
        _ data: Data,
        format: FileFormat?,
        path: String
    ) throws {
        try PersistedFileSecurityPolicy.validateGitCandidate(
            data,
            format: format,
            path: path
        )
    }

    private func validateTreeBounds(
        _ tree: String,
        displayPath: String
    ) async throws {
        let listing = try await commandRunner.runData(
            ["ls-tree", "-r", "-z", "--name-only", tree],
            in: URL(fileURLWithPath: repoPath, isDirectory: true),
            maximumCapturedBytes: GitTemporaryIndexWorkspace
                .maximumTreeListingBytes + 1
        )
        try GitTemporaryIndexWorkspace.validateTreeListing(
            listing,
            path: displayPath
        )
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
    private func run(
        _ arguments: [String],
        gitIndexFile: URL? = nil
    ) async throws -> String {
        try await commandRunner.run(
            arguments,
            in: URL(fileURLWithPath: repoPath, isDirectory: true),
            gitIndexFile: gitIndexFile
        )
    }
}
