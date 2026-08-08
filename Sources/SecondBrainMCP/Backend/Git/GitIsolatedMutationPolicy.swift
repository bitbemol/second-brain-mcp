import Darwin
import Foundation

/// Private, bounded storage for Git indexes that must never alias the user's
/// real staging index. The recognizable prefix is used only for conservative
/// cleanup of old app-owned directories; every live directory is UUID-random,
/// owned by this uid, and mode 0700.
struct GitTemporaryIndexWorkspace: Sendable {
    struct IndexEntry: Equatable, Sendable {
        let mode: String
        let objectID: String
        let stage: String
        let path: String
    }

    static let directoryPrefix = "SecondBrainMCP-git-index-"
    // Many independent vaults can legitimately serve in one host. The bound is
    // high enough for that fan-out while still preventing abandoned temp roots
    // from growing without limit.
    static let maximumArtifacts = 256
    static let staleArtifactAge: TimeInterval = 24 * 60 * 60
    static let maximumTreeEntries = 100_000
    static let maximumTreeListingBytes = 16 * 1024 * 1024
    static let maximumIndexBytes = 64 * 1024 * 1024

    let directory: URL
    let file: URL

    static func create() throws -> Self {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let liveCount = try scavengeStaleArtifacts(in: temporaryDirectory)
        guard liveCount < maximumArtifacts else {
            throw GitRepository.UnsafeStartupSnapshot(
                path: "isolated Git index capacity"
            )
        }
        let directory = temporaryDirectory.appendingPathComponent(
            directoryPrefix + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var metadata = stat()
        guard Darwin.lstat(directory.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & 0o777 == 0o700 else {
            try? FileManager.default.removeItem(at: directory)
            throw GitRepository.UnsafeStartupSnapshot(
                path: "isolated Git index storage"
            )
        }
        return Self(
            directory: directory,
            file: directory.appendingPathComponent("index")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func validateMaterializedIndex() throws {
        var metadata = stat()
        guard Darwin.lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= Self.maximumIndexBytes else {
            throw GitRepository.UnsafeStartupSnapshot(
                path: "isolated Git index size"
            )
        }
    }

    /// Removes only old, exact-prefix, UUID-named directories owned by this uid
    /// with the private mode used at creation. Symlinks and unexpected nodes are
    /// ignored rather than followed or removed.
    @discardableResult
    static func scavengeStaleArtifacts(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
        staleAge: TimeInterval = staleArtifactAge
    ) throws -> Int {
        let names = try FileManager.default.contentsOfDirectory(
            atPath: temporaryDirectory.path
        )
        var liveCount = 0
        for name in names where name.hasPrefix(directoryPrefix) {
            let suffix = String(name.dropFirst(directoryPrefix.count))
            guard UUID(uuidString: suffix) != nil else { continue }
            let url = temporaryDirectory.appendingPathComponent(
                name,
                isDirectory: true
            )
            var metadata = stat()
            guard Darwin.lstat(url.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == Darwin.geteuid(),
                  metadata.st_mode & 0o777 == 0o700 else {
                continue
            }
            let modified = Date(
                timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
            )
            if now.timeIntervalSince(modified) >= staleAge {
                try? FileManager.default.removeItem(at: url)
                if FileManager.default.fileExists(atPath: url.path) {
                    liveCount += 1
                }
            } else {
                liveCount += 1
            }
        }
        return liveCount
    }

    static func validateTreeListing(_ data: Data, path: String) throws {
        guard data.count <= maximumTreeListingBytes,
              data.isEmpty || data.last == 0 else {
            throw GitRepository.UnsafeStartupSnapshot(path: path)
        }
        var entryCount = 0
        for byte in data where byte == 0 {
            entryCount += 1
            guard entryCount <= maximumTreeEntries else {
                throw GitRepository.UnsafeStartupSnapshot(path: path)
            }
        }
    }

    static func maximumIndexManifestBytes(objectFormat: String) throws -> Int {
        let hashBytes: Int
        switch objectFormat {
        case "sha1": hashBytes = 40
        case "sha256": hashBytes = 64
        default:
            throw GitRepository.UnsafeStartupSnapshot(
                path: "unsupported Git object format"
            )
        }
        let (overhead, overflow) = maximumTreeEntries
            .multipliedReportingOverflow(by: hashBytes + 11)
        let (maximum, totalOverflow) = maximumTreeListingBytes
            .addingReportingOverflow(overhead)
        guard !overflow, !totalOverflow else {
            throw GitRepository.UnsafeStartupSnapshot(path: "Git index manifest")
        }
        return maximum
    }

    static func parseIndexManifest(
        _ data: Data,
        maximumBytes: Int,
        objectFormat: String,
        displayPath: String
    ) throws -> [String: IndexEntry] {
        let hashBytes = objectFormat == "sha256" ? 64 : 40
        guard (objectFormat == "sha1" || objectFormat == "sha256"),
              data.count <= maximumBytes,
              data.isEmpty || data.last == 0 else {
            throw GitRepository.UnsafeStartupSnapshot(path: displayPath)
        }
        guard !data.isEmpty else { return [:] }
        let records = data.split(
            separator: 0,
            omittingEmptySubsequences: false
        )
        guard records.last?.isEmpty == true else {
            throw GitRepository.UnsafeStartupSnapshot(path: displayPath)
        }
        var entries: [String: IndexEntry] = [:]
        for rawRecord in records.dropLast() {
            guard !rawRecord.isEmpty,
                  entries.count < maximumTreeEntries,
                  let tab = rawRecord.firstIndex(of: 9),
                  let header = String(
                    data: Data(rawRecord[..<tab]),
                    encoding: .utf8
                  ),
                  let path = String(
                    data: Data(rawRecord[rawRecord.index(after: tab)...]),
                    encoding: .utf8
                  ),
                  !path.isEmpty else {
                throw GitRepository.UnsafeStartupSnapshot(path: displayPath)
            }
            let fields = header.split(separator: " ")
            guard fields.count == 3,
                  fields[0].count == 6,
                  fields[1].count == hashBytes,
                  fields[1].allSatisfy({ $0.isHexDigit }),
                  fields[2].count == 1,
                  ["0", "1", "2", "3"].contains(String(fields[2])) else {
                throw GitRepository.UnsafeStartupSnapshot(path: path)
            }
            let entry = IndexEntry(
                mode: String(fields[0]),
                objectID: String(fields[1]),
                stage: String(fields[2]),
                path: path
            )
            guard entries.updateValue(entry, forKey: path) == nil else {
                throw GitRepository.UnsafeStartupSnapshot(path: path)
            }
        }
        return entries
    }
}

/// Internal replay identity recorded as exact terminal Git trailer lines.
struct GitMutationIdentity: Equatable, Sendable {
    let identifier: MutationID
    let fingerprint: MutationRequestFingerprint
}

/// Builds and validates mutation-only Git trees away from the user's real index.
///
/// `GitRepository` owns this value and invokes it through actor-isolated methods,
/// retaining one repository serialization boundary while keeping startup snapshot
/// policy separate from ordinary CRUD and directory-move commits.
struct GitIsolatedMutationPolicy: Sendable {
    private struct IsolatedIndex {
        let directory: URL
        let file: URL
        let originalHead: String
        let originalTree: String
        let objectFormat: String
    }

    private let repoPath: String
    private let commandRunner: GitCommandRunner
    private let validatedObserver: (@Sendable () throws -> Void)?
    private let candidateTreeCreatedObserver: (@Sendable (URL) throws -> Void)?

    init(
        repoPath: String,
        commandRunner: GitCommandRunner,
        validatedObserver: (@Sendable () throws -> Void)?,
        candidateTreeCreatedObserver: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.repoPath = repoPath
        self.commandRunner = commandRunner
        self.validatedObserver = validatedObserver
        self.candidateTreeCreatedObserver = candidateTreeCreatedObserver
    }

    func commitChange(
        file: String,
        expectedRevision: FileRevision,
        maximumBytes: Int,
        message: String,
        identity: GitMutationIdentity?
    ) async throws {
        let isolated = try await prepareIsolatedIndex()
        defer { try? FileManager.default.removeItem(at: isolated.directory) }
        try await run([
            "--literal-pathspecs", "add", "-f", "-A", "--", file,
        ], gitIndexFile: isolated.file)
        try await run([
            "--literal-pathspecs", "update-index", "--chmod=-x", "--", file,
        ], gitIndexFile: isolated.file)
        try await validateStagedFile(
            path: file,
            expectedRevision: expectedRevision,
            maximumBytes: maximumBytes,
            index: isolated.file
        )
        try validatedObserver?()
        try await commitIsolatedIndex(
            isolated,
            message: message,
            ownedPaths: [file],
            identity: identity
        )
    }

    func commitDeletion(
        path: String,
        message: String,
        identity: GitMutationIdentity?
    ) async throws {
        let isolated = try await prepareIsolatedIndex()
        defer { try? FileManager.default.removeItem(at: isolated.directory) }
        let trackedBefore = try await run([
            "--literal-pathspecs", "ls-files", "-s", "--", path,
        ], gitIndexFile: isolated.file)
        let worktreeURL = URL(fileURLWithPath: repoPath, isDirectory: true)
            .appendingPathComponent(path)
        if !trackedBefore.isEmpty
            || FileManager.default.fileExists(atPath: worktreeURL.path) {
            try await run([
                "--literal-pathspecs", "add", "-f", "-A", "--", path,
            ], gitIndexFile: isolated.file)
        }
        let staged = try await run([
            "--literal-pathspecs", "ls-files", "-s", "-z", "--", path,
        ], gitIndexFile: isolated.file)
        guard staged.isEmpty else {
            throw GitRepository.UnsafeStartupSnapshot(path: path)
        }
        try validatedObserver?()
        try await commitIsolatedIndex(
            isolated,
            message: message,
            ownedPaths: [path],
            allowUnchangedTree: true,
            identity: identity
        )
    }

    func commitMove(
        sourcePath: String,
        destinationPath: String,
        manifest suppliedManifest: DirectoryMoveSecurityPreflight.Manifest?,
        message: String,
        identity: GitMutationIdentity?
    ) async throws {
        let isolated = try await prepareIsolatedIndex()
        defer { try? FileManager.default.removeItem(at: isolated.directory) }
        try await run([
            "--literal-pathspecs", "rm", "-r", "--cached", "--ignore-unmatch",
            "--", sourcePath,
        ], gitIndexFile: isolated.file)
        try await run([
            "--literal-pathspecs", "add", "-f", "-A", "--", destinationPath,
        ], gitIndexFile: isolated.file)

        let manifest: DirectoryMoveSecurityPreflight.Manifest
        if let suppliedManifest {
            guard suppliedManifest.rootPath == destinationPath else {
                throw GitRepository.UnsafeStartupSnapshot(path: destinationPath)
            }
            manifest = suppliedManifest
        } else {
            let destination = try NotesDirectoryTarget.resolve(
                path: destinationPath,
                vaultPath: repoPath
            )
            manifest = try DirectoryMoveSecurityPreflight.validate(destination)
        }
        try await validateMoveIndex(
            isolated.file,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            manifest: manifest,
            objectFormat: isolated.objectFormat
        )
        try validatedObserver?()
        try await commitIsolatedIndex(
            isolated,
            message: message,
            ownedPaths: [sourcePath, destinationPath],
            allowUnchangedTree: true,
            identity: identity
        )
    }

    func reconcileCommittedMove(
        sourcePath: String,
        destinationPath: String
    ) async throws {
        try await reconcileCommittedPaths([sourcePath, destinationPath])
    }

    func reconcileCommittedChange(path: String) async throws {
        try await reconcileCommittedPaths([path])
    }

    func containsMutationCommit(
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint
    ) async throws -> Bool {
        let mutationLine = Self.mutationTrailer(identity: identifier)
        let requestLine = Self.requestTrailer(fingerprint: fingerprint)
        let hashes = try await run([
            "log",
            "--extended-regexp",
            "--all-match",
            "--grep=^\(NSRegularExpression.escapedPattern(for: mutationLine))$",
            "--grep=^\(NSRegularExpression.escapedPattern(for: requestLine))$",
            "--format=%H",
            "--max-count=129",
        ]).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard hashes.count <= 128 else {
            throw GitRepository.UnsafeStartupSnapshot(
                path: "ambiguous mutation history"
            )
        }
        for hash in hashes {
            let message = try await run([
                "show", "-s", "--format=%B", "--no-patch", hash,
            ])
            if Self.hasTerminalIdentity(
                message,
                mutationLine: mutationLine,
                requestLine: requestLine
            ) {
                return true
            }
        }
        return false
    }

    private func prepareIsolatedIndex() async throws -> IsolatedIndex {
        let workspace = try GitTemporaryIndexWorkspace.create()
        do {
            let originalHead = try await run(["rev-parse", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let originalTree = try await run(["rev-parse", "HEAD^{tree}"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let objectFormat = try await run(["rev-parse", "--show-object-format"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard objectFormat == "sha1" || objectFormat == "sha256" else {
                throw GitRepository.UnsafeStartupSnapshot(
                    path: "unsupported Git object format"
                )
            }
            let isolated = IsolatedIndex(
                directory: workspace.directory,
                file: workspace.file,
                originalHead: originalHead,
                originalTree: originalTree,
                objectFormat: objectFormat
            )
            try await validateTreeBounds(
                originalTree,
                displayPath: "repository Git tree"
            )
            try await run(["read-tree", originalHead], gitIndexFile: isolated.file)
            try workspace.validateMaterializedIndex()
            return isolated
        } catch {
            workspace.remove()
            throw error
        }
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

    private func validateStagedFile(
        path: String,
        expectedRevision: FileRevision,
        maximumBytes: Int,
        index: URL
    ) async throws {
        let output = try await run([
            "--literal-pathspecs", "ls-files", "-s", "-z", "--", path,
        ], gitIndexFile: index)
        let records = output.split(separator: "\0", omittingEmptySubsequences: true)
        guard records.count == 1,
              let separator = records[0].firstIndex(of: "\t") else {
            throw GitRepository.UnsafeStartupSnapshot(path: path)
        }
        let record = records[0]
        let fields = record[..<separator].split(separator: " ")
        let stagedPath = String(record[record.index(after: separator)...])
        guard stagedPath == path,
              fields.count == 3,
              fields[2] == "0",
              fields[0] == "100644" else {
            throw GitRepository.UnsafeStartupSnapshot(path: path)
        }
        let blobID = String(fields[1])
        let blob = try await commandRunner.runData(
            ["cat-file", "blob", blobID],
            in: URL(fileURLWithPath: repoPath, isDirectory: true),
            maximumCapturedBytes: maximumBytes + 1,
            gitIndexFile: index
        )
        guard blob.count <= maximumBytes,
              FileSnapshot(data: blob, modifiedDate: nil).revision
                == expectedRevision else {
            throw GitRepository.UnsafeStartupSnapshot(path: path)
        }
    }

    private func commitIsolatedIndex(
        _ isolated: IsolatedIndex,
        message: String,
        ownedPaths: [String],
        allowUnchangedTree: Bool = false,
        identity: GitMutationIdentity?
    ) async throws {
        let tree = try await run(["write-tree"], gitIndexFile: isolated.file)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try candidateTreeCreatedObserver?(isolated.file)
        try GitTemporaryIndexWorkspace(
            directory: isolated.directory,
            file: isolated.file
        ).validateMaterializedIndex()
        try await validateTreeBounds(
            tree,
            displayPath: "candidate Git tree"
        )
        guard allowUnchangedTree || tree != isolated.originalTree else {
            throw GitRepository.UnsafeStartupSnapshot(
                path: ownedPaths.first ?? "unchanged mutation"
            )
        }
        let commit = try await run([
            "commit-tree", tree, "-p", isolated.originalHead,
            "-m", Self.commitMessage(message, identity: identity),
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        try await run(["update-ref", "HEAD", commit, isolated.originalHead])
        try await reconcileCommittedPaths(ownedPaths)
    }

    private func reconcileCommittedPaths(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await run([
            "--literal-pathspecs", "reset", "-q", "HEAD", "--",
        ] + paths)
    }

    private func validateMoveIndex(
        _ index: URL,
        sourcePath: String,
        destinationPath: String,
        manifest: DirectoryMoveSecurityPreflight.Manifest,
        objectFormat: String
    ) async throws {
        let sourceEntries = try await commandRunner.runData(
            ["--literal-pathspecs", "ls-files", "-s", "-z", "--", sourcePath],
            in: URL(fileURLWithPath: repoPath, isDirectory: true),
            maximumCapturedBytes: 1,
            gitIndexFile: index
        )
        guard sourceEntries.isEmpty else {
            throw GitRepository.UnsafeStartupSnapshot(path: sourcePath)
        }
        let maximumOutputBytes = try Self.maximumMoveIndexOutputBytes(
            manifest: manifest,
            objectFormat: objectFormat,
            destinationPath: destinationPath
        )
        let outputData = try await commandRunner.runData(
            [
                "--literal-pathspecs", "ls-files", "-s", "-z", "--",
                destinationPath,
            ],
            in: URL(fileURLWithPath: repoPath, isDirectory: true),
            maximumCapturedBytes: maximumOutputBytes + 1,
            gitIndexFile: index
        )
        try Self.validateMoveIndexOutput(
            outputData,
            maximumOutputBytes: maximumOutputBytes,
            destinationPath: destinationPath,
            manifest: manifest,
            objectFormat: objectFormat
        )
    }

    static func maximumMoveIndexOutputBytes(
        manifest: DirectoryMoveSecurityPreflight.Manifest,
        objectFormat: String,
        destinationPath: String
    ) throws -> Int {
        let hashBytes = objectFormat == "sha256" ? 64 : 40
        let (recordOverhead, overheadOverflow) = manifest.entries.count
            .multipliedReportingOverflow(by: hashBytes + 11)
        let (maximumOutputBytes, outputOverflow) = manifest.aggregatePathBytes
            .addingReportingOverflow(recordOverhead)
        guard !overheadOverflow, !outputOverflow,
              maximumOutputBytes < Int.max else {
            throw GitRepository.UnsafeStartupSnapshot(path: destinationPath)
        }
        return maximumOutputBytes
    }

    static func validateMoveIndexOutput(
        _ outputData: Data,
        maximumOutputBytes: Int,
        destinationPath: String,
        manifest: DirectoryMoveSecurityPreflight.Manifest,
        objectFormat: String
    ) throws {
        let parsed = try GitTemporaryIndexWorkspace.parseIndexManifest(
            outputData,
            maximumBytes: maximumOutputBytes,
            objectFormat: objectFormat,
            displayPath: destinationPath
        )
        var staged: [String: String] = [:]
        for (path, entry) in parsed {
            guard entry.stage == "0",
                  entry.mode == "100644" || entry.mode == "100755",
                  entry.mode == manifest.entries[path]?.gitMode else {
                throw GitRepository.UnsafeStartupSnapshot(path: path)
            }
            staged[path] = entry.objectID
        }
        let stagedPaths = Set(staged.keys)
        let manifestPaths = Set(manifest.entries.keys)
        if let missing = manifestPaths.subtracting(stagedPaths).sorted().first {
            throw GitRepository.UnsafeStartupSnapshot(path: missing)
        }
        if let unexpected = stagedPaths.subtracting(manifestPaths).sorted().first {
            throw GitRepository.UnsafeStartupSnapshot(path: unexpected)
        }
        for (path, entry) in manifest.entries {
            let expected = objectFormat == "sha256" ? entry.gitSHA256 : entry.gitSHA1
            guard staged[path] == expected else {
                throw GitRepository.UnsafeStartupSnapshot(path: path)
            }
        }
    }

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

    private static func commitMessage(
        _ message: String,
        identity: GitMutationIdentity?
    ) -> String {
        let subject = sanitizeCommitMessage(message)
        guard let identity else { return subject }
        return subject + "\n\n"
            + mutationTrailer(identity: identity.identifier) + "\n"
            + requestTrailer(fingerprint: identity.fingerprint)
    }

    private static func mutationTrailer(identity: MutationID) -> String {
        "SecondBrain-Mutation-ID: \(identity.rawValue)"
    }

    private static func requestTrailer(
        fingerprint: MutationRequestFingerprint
    ) -> String {
        "SecondBrain-Request-Fingerprint: \(fingerprint.rawValue)"
    }

    private static func hasTerminalIdentity(
        _ message: String,
        mutationLine: String,
        requestLine: String
    ) -> Bool {
        var lines = message.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        while lines.last == "" { lines.removeLast() }
        guard lines.count >= 2 else { return false }
        return lines[lines.count - 2] == mutationLine
            && lines[lines.count - 1] == requestLine
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
