import Darwin
import Foundation
import Security
import Subprocess

/// Records recoverable note snapshots in product-owned Git storage.
///
/// The managed vault is only a work tree. Its user-facing `.git`, index, HEAD,
/// refs, objects, configuration, attributes, locks, and maintenance are never
/// part of this boundary.
actor GitRepository: VaultVersioning {
    private static let snapshotMessage = "Vault snapshot"
    static let snapshotReferencePrefix = "refs/second-brain-mcp/snapshots/"
    static let emptyTreeObject = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    private static let maximumOutputBytes = 32 * 1024
    private static let defaultSnapshotTimeout: Duration = .seconds(120)
    private static let attributePolicy = """
        notes/** -filter -text -crlf -ident -working-tree-encoding -eol

        """

    private let vaultURL: URL
    private let vaultRootIdentity: VaultRootIdentity
    private let privateDataRootURL: URL
    private let privateDataRootIdentity: VaultRootIdentity
    private let snapshotRepositoryURL: URL
    private let snapshotWorkspaceDirectoryURL: URL
    private let snapshotLock: POSIXAdvisoryFileLock
    private let gitExecutableResolver: @Sendable () throws -> URL
    private let gitExecutableValidator: @Sendable (URL) -> Bool
    private var gitExecutableURL: URL?
    private let snapshotTimeout: Duration
    private let preSnapshotLockObserver: (@Sendable () throws -> Void)?
    private let postStageObserver: (@Sendable () throws -> Void)?
    private var didProbeGitExecutable = false
    private var activeSnapshotLease: POSIXAdvisoryFileLock.Lease?

    init(
        vaultURL: URL,
        dataDirectory: VaultDataDirectory,
        snapshotTimeout: Duration = GitRepository.defaultSnapshotTimeout,
        preSnapshotLockObserver: (@Sendable () throws -> Void)? = nil,
        postStageObserver: (@Sendable () throws -> Void)? = nil,
        gitExecutableResolver: @escaping @Sendable () throws -> URL = {
            try AppleGitExecutable.resolve()
        },
        gitExecutableValidator: @escaping @Sendable (URL) -> Bool = {
            AppleGitExecutable.isTrusted($0)
        }
    ) throws {
        guard vaultURL.isFileURL,
              dataDirectory.snapshotRepositoryURL.isFileURL,
              dataDirectory.snapshotWorkspaceDirectoryURL.isFileURL else {
            throw VaultVersioningError.invalidRepositoryURL
        }
        precondition(snapshotTimeout > .zero, "Git snapshot timeout must be positive")
        let canonicalVaultURL = vaultURL.standardizedFileURL.resolvingSymlinksInPath()
        self.vaultURL = canonicalVaultURL
        self.vaultRootIdentity = try VaultRootIdentity.capture(
            canonicalVaultURL
        )
        let canonicalDataRootURL = dataDirectory.rootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        self.privateDataRootURL = canonicalDataRootURL
        let capturedPrivateDataRootIdentity = try VaultRootIdentity.capture(
            canonicalDataRootURL
        )
        self.privateDataRootIdentity = capturedPrivateDataRootIdentity
        let canonicalLockDirectoryURL = dataDirectory.lockDirectoryURL
            .standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalLockDirectoryURL.deletingLastPathComponent()
            == canonicalDataRootURL else {
            throw VaultVersioningError.invalidRepositoryURL
        }
        let lockDirectoryIdentity = try VaultRootIdentity.capture(
            canonicalLockDirectoryURL
        )
        self.snapshotRepositoryURL = dataDirectory.snapshotRepositoryURL
            .standardizedFileURL.resolvingSymlinksInPath()
        self.snapshotWorkspaceDirectoryURL = dataDirectory.snapshotWorkspaceDirectoryURL
            .standardizedFileURL.resolvingSymlinksInPath()
        let snapshotLockURL = canonicalLockDirectoryURL.appendingPathComponent(
            "git-snapshot.lock"
        )
        self.snapshotLock = POSIXAdvisoryFileLock(
            url: snapshotLockURL,
            descriptorOpener: {
                try PrivateSnapshotLockFile.open(
                    rootURL: canonicalDataRootURL,
                    rootIdentity: capturedPrivateDataRootIdentity,
                    directoryName: canonicalLockDirectoryURL.lastPathComponent,
                    directoryIdentity: lockDirectoryIdentity,
                    fileName: snapshotLockURL.lastPathComponent
                )
            }
        )
        self.gitExecutableResolver = gitExecutableResolver
        self.gitExecutableValidator = gitExecutableValidator
        self.gitExecutableURL = nil
        self.snapshotTimeout = snapshotTimeout
        self.preSnapshotLockObserver = preSnapshotLockObserver
        self.postStageObserver = postStageObserver
    }

    func recordSnapshot() async throws {
        try await recordSnapshot(scope: nil)
    }

    func prepareForMutation(changing paths: [String]?) async throws {
        if let paths {
            try await recordSnapshot(scope: normalizedSnapshotPaths(paths))
        } else {
            try await recordSnapshot()
        }
    }

    func recordSnapshot(changing paths: [String]) async throws {
        try await recordSnapshot(scope: normalizedSnapshotPaths(paths))
    }

    private func recordSnapshot(scope paths: [String]?) async throws {
        try validatePrivateDataRoot()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: snapshotTimeout)
        try preSnapshotLockObserver?()
        let lease: POSIXAdvisoryFileLock.Lease
        do {
            lease = try await snapshotLock.acquire(.exclusive, deadline: deadline)
        } catch is POSIXAdvisoryFileLock.DeadlineExceeded {
            throw VaultVersioningError.gitCommandTimedOut(arguments: ["snapshot-lock"])
        }
        activeSnapshotLease = lease
        defer {
            activeSnapshotLease = nil
            lease.release()
        }
        try validatePrivateDataRoot()
        if let gitExecutableURL,
           !gitExecutableValidator(gitExecutableURL) {
            self.gitExecutableURL = nil
            didProbeGitExecutable = false
        }
        if gitExecutableURL == nil {
            gitExecutableURL = try gitExecutableResolver()
        }
        if !didProbeGitExecutable {
            try await requireSuccess(
                ["--version"],
                deadline: deadline,
                initialization: true
            )
            didProbeGitExecutable = true
        }
        try await performSnapshot(deadline: deadline, changing: paths)
    }
}

private extension GitRepository {
    struct GitResult: Sendable {
        let status: TerminationStatus
        let standardOutput: String
        let standardError: String
    }

    struct GitCommandDeadlineExceeded: Error {}

    struct GitlinkScanResult: Sendable {
        let status: TerminationStatus
        let standardError: String
        let containsGitlink: Bool
        let containsUnsupportedMode: Bool
    }

    final class NotesEnumerationErrors: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var encountered: Bool {
            lock.withLock { value }
        }

        func mark() {
            lock.withLock { value = true }
        }
    }

    struct SnapshotBase {
        let reference: String?
        let commit: String?
        let nextSequence: UInt64
    }

    func normalizedSnapshotPaths(_ paths: [String]) throws -> [String] {
        let unique = Array(Set(paths)).sorted()
        guard !unique.isEmpty, unique.count <= 2 else {
            throw invalidSnapshotState(arguments: ["snapshot-paths"])
        }
        for path in unique {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.utf8.count <= PathMoveRequestLimits.maximumPathBytes,
                  !PathTraversalDetector.containsTraversal(in: path),
                  components.count >= 2,
                  components.first == "notes",
                  components.allSatisfy({
                      !$0.isEmpty
                          && $0 != "."
                          && $0 != ".."
                          && $0 != ".git"
                          && !$0.contains("\0")
                          && $0.utf8.count <= 255
                  }),
                  components.dropFirst().dropLast().allSatisfy({
                      !$0.hasPrefix(".")
                  }) else {
                throw invalidSnapshotState(arguments: ["snapshot-paths"])
            }
        }
        return unique
    }

    /// Uses a unique private index and immutable ref leaf for every transaction.
    /// A killed child can therefore strand only product-owned temporary state
    /// that no later snapshot reuses.
    func performSnapshot(
        deadline: ContinuousClock.Instant,
        changing requestedPaths: [String]?
    ) async throws {
        try Task.checkCancellation()
        try validateSnapshotRoots()
        try await initializeRepository(deadline: deadline)
        let base = try await latestSnapshotBase(deadline: deadline)
        try validatePrivateDataRoot()
        let workspace = try GitSnapshotIndexWorkspace.create(
            in: snapshotWorkspaceDirectoryURL,
            deadline: deadline
        )
        defer { workspace.remove() }
        try validatePrivateDataRoot()

        // Startup recovery reconciles the complete notes tree. Interactive MCP
        // mutations seed from the latest snapshot when one exists, then stage
        // only the one or two paths protected by that operation.
        let scopedPaths = requestedPaths
        if let commit = base.commit, scopedPaths != nil {
            try await requireSuccess(
                ["read-tree", "\(commit)^{tree}"],
                index: workspace.file,
                deadline: deadline
            )
        } else {
            try await requireSuccess(
                ["read-tree", "--empty"],
                index: workspace.file,
                deadline: deadline
            )
            let emptyTree = try await requireOutput(
                ["write-tree"],
                index: workspace.file,
                deadline: deadline
            )
            guard emptyTree == Self.emptyTreeObject else {
                throw invalidSnapshotState(arguments: ["write-tree"])
            }
        }

        let matchedNotes = try await stageNotes(
            index: workspace.file,
            paths: scopedPaths,
            deadline: deadline
        )
        try postStageObserver?()
        // Reject path replacement before traversing whatever now occupies it.
        try validateSnapshotRoots()
        if matchedNotes {
            try await validateStagedEntryModes(
                index: workspace.file,
                paths: scopedPaths,
                deadline: deadline
            )
        }
        if scopedPaths == nil {
            _ = try validateSupportedNotesEntries(deadline: deadline)
        }
        // Staging and enumeration dereference the work-tree pathname. Recheck
        // the captured root identity before every success path, including
        // empty/no-op paths.
        try validateSnapshotRoots()
        if !matchedNotes, base.commit == nil {
            return
        }
        let tree = try await requireOutput(
            ["write-tree"],
            index: workspace.file,
            deadline: deadline
        )
        if let commit = base.commit {
            let previousTree = try await requireOutput(
                ["rev-parse", "--verify", "\(commit)^{tree}"],
                deadline: deadline
            )
            guard tree != previousTree else { return }
        }

        var commitArguments = [
            "-c", "user.name=SecondBrainMCP",
            "-c", "user.email=secondbrainmcp@localhost",
            "commit-tree", tree,
        ]
        if let commit = base.commit {
            commitArguments += ["-p", commit]
        }
        commitArguments += ["-m", Self.snapshotMessage]
        let commit = try await requireOutput(commitArguments, deadline: deadline)
        let reference = snapshotReference(sequence: base.nextSequence)

        // This is the durability boundary. Only a newly named ref is required;
        // no user ref or reusable ref-lock path participates.
        try validateSnapshotRoots()
        try await requireSuccess(
            ["update-ref", reference, commit],
            deadline: deadline,
            inheritSnapshotLease: true
        )

        // The new commit retains its parent. Old-leaf cleanup is optional and
        // never converts an already durable snapshot into a reported failure.
        if let previousReference = base.reference,
           let previousCommit = base.commit {
            _ = try? await executeGit(
                ["update-ref", "-d", previousReference, previousCommit],
                deadline: deadline
            )
        }
    }

    /// First initialization is built under a UUID path and installed atomically.
    /// Once valid, the durable repository is never reinitialized, so a stale
    /// fixed `config.lock` cannot block later snapshots.
    func initializeRepository(deadline: ContinuousClock.Instant) async throws {
        try validatePrivateDataRoot()
        if repositoryPathExists(snapshotRepositoryURL) {
            try retightenPrivateRepositoryRoot(snapshotRepositoryURL)
            try validatePrivateRepositoryDirectory(snapshotRepositoryURL)
            let probeArguments = ["rev-parse", "--is-bare-repository"]
            let probe = try await executeGit(
                probeArguments,
                deadline: deadline,
                gitDirectory: snapshotRepositoryURL,
                bareRepositoryOnly: true
            )
            guard probe.status.isSuccess,
                  probe.standardOutput.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ) == "true" else {
                throw commandFailure(arguments: probeArguments, result: probe)
            }
            try installAttributePolicy(in: snapshotRepositoryURL)
            return
        }

        let temporaryRepository = snapshotRepositoryURL.deletingLastPathComponent()
            .appendingPathComponent(
                "git-snapshots-init-\(UUID().uuidString)",
                isDirectory: true
            )
        var temporaryRepositoryIdentity: VaultRootIdentity?
        defer {
            if privateDataRootIdentity.matches(privateDataRootURL),
               temporaryRepositoryIdentity?.matches(temporaryRepository) == true {
                try? FileManager.default.removeItem(at: temporaryRepository)
            }
        }
        try await requireSuccess(
            [
                "init", "--bare", "--object-format=sha1", "--ref-format=files",
                temporaryRepository.path(percentEncoded: false),
            ],
            deadline: deadline,
            initialization: true
        )
        temporaryRepositoryIdentity = try VaultRootIdentity.capture(
            temporaryRepository
        )
        try validatePrivateDataRoot()
        guard Darwin.chmod(temporaryRepository.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try validatePrivateDataRoot()
        try validatePrivateRepositoryDirectory(temporaryRepository)
        try installAttributePolicy(in: temporaryRepository)
        try Task.checkCancellation()
        try validatePrivateDataRoot()
        try FileManager.default.moveItem(
            at: temporaryRepository,
            to: snapshotRepositoryURL
        )
        try validatePrivateDataRoot()
    }

    /// Repair only permissions on the already-opened, current-user-owned product
    /// directory. `O_NOFOLLOW` keeps a substituted link outside this boundary.
    func retightenPrivateRepositoryRoot(_ url: URL) throws {
        let parent = try openValidatedPrivateDataRoot()
        defer { Darwin.close(parent) }
        let descriptor = Darwin.openat(
            parent,
            url.lastPathComponent,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw VaultVersioningError.invalidPrivateRepository
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid() else {
            throw VaultVersioningError.invalidPrivateRepository
        }
        if metadata.st_mode & 0o777 != 0o700,
           Darwin.fchmod(descriptor, 0o700) != 0 {
            throw VaultVersioningError.invalidPrivateRepository
        }
        try validatePrivateDataRoot()
    }

    func validatePrivateDataRoot() throws {
        guard privateDataRootIdentity.matches(privateDataRootURL) else {
            throw VaultVersioningError.invalidPrivateRepository
        }
    }

    func openValidatedPrivateDataRoot() throws -> Int32 {
        let descriptor = Darwin.open(
            privateDataRootURL.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw VaultVersioningError.invalidPrivateRepository
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              privateDataRootIdentity.matches(metadata) else {
            Darwin.close(descriptor)
            throw VaultVersioningError.invalidPrivateRepository
        }
        return descriptor
    }

    func installAttributePolicy(in repository: URL) throws {
        let infoDirectory = repository.appendingPathComponent(
            "info",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: infoDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(Self.attributePolicy.utf8).write(
            to: infoDirectory.appendingPathComponent("attributes"),
            options: .atomic
        )
    }

    func repositoryPathExists(_ url: URL) -> Bool {
        var value = stat()
        return Darwin.lstat(url.path, &value) == 0
    }

    func validatePrivateRepositoryDirectory(_ url: URL) throws {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == Darwin.geteuid(),
              value.st_mode & 0o077 == 0 else {
            throw VaultVersioningError.invalidPrivateRepository
        }

        for path in [
            "info", "objects", "objects/info", "objects/pack", "refs",
            "refs/heads", "refs/tags",
        ] {
            try requireOwnedRepositoryNode(
                url.appendingPathComponent(path),
                type: S_IFDIR
            )
        }
        for path in ["HEAD", "config", "description", "info/exclude"] {
            try requireOwnedRepositoryNode(
                url.appendingPathComponent(path),
                type: S_IFREG
            )
        }
        for path in [
            "refs/second-brain-mcp",
            "refs/second-brain-mcp/snapshots",
        ] {
            try validateOptionalOwnedRepositoryNode(
                url.appendingPathComponent(path),
                type: S_IFDIR
            )
        }
        for path in ["info/attributes", "packed-refs"] {
            try validateOptionalOwnedRepositoryNode(
                url.appendingPathComponent(path),
                type: S_IFREG
            )
        }
        for path in [
            "commondir", "gitdir", "objects/info/alternates",
            "objects/info/http-alternates",
        ] where repositoryPathExists(url.appendingPathComponent(path)) {
            throw VaultVersioningError.invalidPrivateRepository
        }
    }

    func requireOwnedRepositoryNode(_ url: URL, type: mode_t) throws {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == type,
              metadata.st_uid == Darwin.geteuid() else {
            throw VaultVersioningError.invalidPrivateRepository
        }
    }

    func validateOptionalOwnedRepositoryNode(
        _ url: URL,
        type: mode_t
    ) throws {
        var metadata = stat()
        if Darwin.lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw VaultVersioningError.invalidPrivateRepository
        }
        guard metadata.st_mode & S_IFMT == type,
              metadata.st_uid == Darwin.geteuid() else {
            throw VaultVersioningError.invalidPrivateRepository
        }
    }

    func latestSnapshotBase(deadline: ContinuousClock.Instant) async throws -> SnapshotBase {
        let reference = try await requireOutput(
            [
                "for-each-ref",
                "--sort=-refname",
                "--count=1",
                "--format=%(refname)",
                Self.snapshotReferencePrefix,
            ],
            deadline: deadline
        )
        if !reference.isEmpty {
            guard reference.hasPrefix(Self.snapshotReferencePrefix) else {
                throw invalidSnapshotState(arguments: ["for-each-ref"])
            }
            let component = String(reference.dropFirst(Self.snapshotReferencePrefix.count))
            guard let separator = component.firstIndex(of: "-"),
                  let sequence = UInt64(component[..<separator]),
                  sequence < UInt64.max else {
                throw invalidSnapshotState(arguments: ["for-each-ref"])
            }
            return SnapshotBase(
                reference: reference,
                commit: try await requireOutput(
                    ["rev-parse", "--verify", "\(reference)^{commit}"],
                    deadline: deadline
                ),
                nextSequence: sequence + 1
            )
        }

        return SnapshotBase(reference: nil, commit: nil, nextSequence: 1)
    }

    /// Stages creations, updates, moves, and deletions below the one fixed notes
    /// scope. Absence is established from the private index and lstat, never
    /// from caller-influenced Git diagnostics.
    func stageNotes(
        index: URL,
        paths: [String]?,
        deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        try validateNotesRoot()
        // Ignore and sparse-checkout policy belong to interactive Git. The
        // empty attribute source prevents root or nested worktree attributes
        // from running filters or transforming recovery bytes.
        if let paths {
            var stagedPath = false
            for path in paths {
                guard try await scopedPathNeedsStaging(
                    path,
                    index: index,
                    deadline: deadline
                ) else {
                    continue
                }
                let arguments = [
                    "add", "--all", "--force", "--sparse", "--", path,
                ]
                let staged = try await executeGit(
                    arguments,
                    index: index,
                    deadline: deadline,
                    isolatedAttributes: true
                )
                guard staged.status.isSuccess else {
                    throw commandFailure(arguments: arguments, result: staged)
                }
                stagedPath = true
            }
            return stagedPath
        }

        let arguments = [
            "add", "--all", "--force", "--sparse", "--", "notes",
        ]
        let staged = try await executeGit(
            arguments,
            index: index,
            deadline: deadline,
            isolatedAttributes: true
        )
        guard !staged.status.isSuccess else { return true }

        // Git reports an empty pathspec as failure. Accept that one state only
        // after independently proving both the work tree and seeded index have
        // no representable note.
        let trackedNotes = try await indexTracks(
            "notes",
            index: index,
            deadline: deadline
        )
        let storedNotes = try validateSupportedNotesEntries(deadline: deadline)
        guard !trackedNotes, !storedNotes else {
            throw commandFailure(arguments: arguments, result: staged)
        }
        return false
    }

    func scopedPathNeedsStaging(
        _ path: String,
        index: URL,
        deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        let target = vaultURL.appendingPathComponent(path)
        var metadata = stat()
        if Darwin.lstat(target.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFREG else {
                throw VaultVersioningError.unsupportedEntryBelowNotes
            }
            return true
        }

        let failure = errno
        guard failure == ENOENT || failure == ENOTDIR else {
            throw CocoaError(.fileReadUnknown)
        }
        return try await indexTracks(path, index: index, deadline: deadline)
    }

    func indexTracks(
        _ path: String,
        index: URL,
        deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        let entries = try await requireOutput(
            ["ls-files", "--cached", "-z", "--", path],
            index: index,
            deadline: deadline
        )
        return !entries.isEmpty
    }

    func snapshotReference(sequence: UInt64) -> String {
        Self.snapshotReferencePrefix
            + String(format: "%020llu", sequence)
            + "-" + UUID().uuidString.lowercased()
    }

    /// Git represents links and embedded repositories as non-file modes.
    /// Stream only fixed-width modes so validation remains constant-memory
    /// even for a very large notes tree.
    func validateStagedEntryModes(
        index: URL,
        paths: [String]?,
        deadline: ContinuousClock.Instant
    ) async throws {
        try validatePrivateDataRoot()
        let arguments = [
            "ls-files", "--format=%(objectmode)", "--",
        ] + (paths ?? ["notes"])
        let clock = ContinuousClock()
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else {
            throw VaultVersioningError.gitCommandTimedOut(arguments: arguments)
        }
        let commandArguments = gitCommandArguments(arguments)
        let environment = Self.gitEnvironment(index: index, isolatedAttributes: false)
        guard let gitExecutableURL else {
            throw VaultVersioningError.trustedGitUnavailable
        }
        let executablePath = gitExecutableURL.path(percentEncoded: false)
        let platformOptions = try gitPlatformOptions(
            inheritSnapshotLease: false
        )

        let scan: GitlinkScanResult
        do {
            scan = try await withThrowingTaskGroup(of: GitlinkScanResult.self) { group in
                group.addTask {
                    let result = try await Subprocess.run(
                        .path(.init(executablePath)),
                        arguments: Arguments(commandArguments),
                        environment: environment,
                        platformOptions: platformOptions,
                        input: .none,
                        output: .sequence,
                        error: .string(limit: Self.maximumOutputBytes)
                    ) { execution in
                        var containsGitlink = false
                        var containsUnsupportedMode = false
                        for try await line in execution.standardOutput.strings() {
                            let mode = line.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            if mode == "160000" {
                                containsGitlink = true
                            } else if mode != "100644" && mode != "100755" {
                                containsUnsupportedMode = true
                            }
                        }
                        return (containsGitlink, containsUnsupportedMode)
                    }
                    return GitlinkScanResult(
                        status: result.terminationStatus,
                        standardError: result.standardError,
                        containsGitlink: result.closureResult.0,
                        containsUnsupportedMode: result.closureResult.1
                    )
                }
                group.addTask {
                    try await Task.sleep(for: remaining)
                    throw GitCommandDeadlineExceeded()
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw GitCommandDeadlineExceeded()
                }
                return result
            }
        } catch is GitCommandDeadlineExceeded {
            throw VaultVersioningError.gitCommandTimedOut(arguments: arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SubprocessError
            where error.code == .spawnFailed || error.code == .executableNotFound {
            // Xcode or Command Line Tools can be replaced while the agent is
            // running. A later recovery attempt must resolve the trusted binary
            // again instead of retaining a path that can no longer launch.
            self.gitExecutableURL = nil
            didProbeGitExecutable = false
            throw VaultVersioningError.trustedGitUnavailable
        } catch {
            throw VaultVersioningError.gitCommandFailed(
                arguments: arguments,
                status: "subprocess execution failed",
                message: ""
            )
        }

        try validatePrivateDataRoot()

        guard scan.status.isSuccess else {
            throw VaultVersioningError.gitCommandFailed(
                arguments: arguments,
                status: scan.status.description,
                message: scan.standardError
            )
        }
        guard !scan.containsGitlink else {
            throw VaultVersioningError.embeddedRepositoryBelowNotes
        }
        guard !scan.containsUnsupportedMode else {
            throw VaultVersioningError.unsupportedEntryBelowNotes
        }
    }

    func validateVaultRoot() throws {
        guard vaultRootIdentity.matches(vaultURL) else {
            throw VaultVersioningError.vaultRootChanged
        }
    }

    func validateSnapshotRoots() throws {
        try validateVaultRoot()
        try validatePrivateDataRoot()
    }

    func validateNotesRoot() throws {
        let notesURL = vaultURL.appendingPathComponent("notes")
        var metadata = stat()
        if Darwin.lstat(notesURL.path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw CocoaError(.fileReadUnknown)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw VaultVersioningError.unsupportedEntryBelowNotes
        }
    }

}

// Internal scan boundary: deadline tests need neither Git setup nor sleeps.
extension GitRepository {
    /// Git silently skips sockets, FIFOs, and device nodes. Walk the notes
    /// namespace without following links so an apparently successful command
    /// cannot certify an incomplete snapshot.
    func validateSupportedNotesEntries(
        deadline: ContinuousClock.Instant
    ) throws -> Bool {
        let deadlineArguments = ["snapshot-filesystem-scan"]
        let clock = ContinuousClock()
        guard clock.now < deadline else {
            throw VaultVersioningError.gitCommandTimedOut(
                arguments: deadlineArguments
            )
        }
        let notesURL = vaultURL.appendingPathComponent("notes")
        var rootMetadata = stat()
        if Darwin.lstat(notesURL.path, &rootMetadata) != 0 {
            if errno == ENOENT { return false }
            throw CocoaError(.fileReadUnknown)
        }
        guard rootMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw VaultVersioningError.unsupportedEntryBelowNotes
        }

        let errors = NotesEnumerationErrors()
        guard let enumerator = FileManager.default.enumerator(
            at: notesURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                errors.mark()
                return false
            }
        ) else {
            throw VaultVersioningError.unsupportedEntryBelowNotes
        }
        var containsRegularFile = false
        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw VaultVersioningError.gitCommandTimedOut(
                    arguments: deadlineArguments
                )
            }
            guard let entry = enumerator.nextObject() as? URL else { break }
            guard clock.now < deadline else {
                throw VaultVersioningError.gitCommandTimedOut(
                    arguments: deadlineArguments
                )
            }
            if entry.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                throw VaultVersioningError.embeddedRepositoryBelowNotes
            }
            var metadata = stat()
            guard Darwin.lstat(entry.path, &metadata) == 0 else {
                throw CocoaError(.fileReadUnknown)
            }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                continue
            case S_IFREG:
                containsRegularFile = true
            default:
                enumerator.skipDescendants()
                throw VaultVersioningError.unsupportedEntryBelowNotes
            }
        }
        guard !errors.encountered else {
            throw VaultVersioningError.unsupportedEntryBelowNotes
        }
        return containsRegularFile
    }
}

private extension GitRepository {
    func executeGit(
        _ arguments: [String],
        index: URL? = nil,
        deadline: ContinuousClock.Instant,
        initialization: Bool = false,
        isolatedAttributes: Bool = false,
        gitDirectory: URL? = nil,
        bareRepositoryOnly: Bool = false,
        inheritSnapshotLease: Bool = false
    ) async throws -> GitResult {
        try Task.checkCancellation()
        try validatePrivateDataRoot()
        let clock = ContinuousClock()
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else {
            throw VaultVersioningError.gitCommandTimedOut(arguments: arguments)
        }

        let commandArguments = gitCommandArguments(
            arguments,
            initialization: initialization,
            isolatedAttributes: isolatedAttributes,
            gitDirectory: gitDirectory,
            bareRepositoryOnly: bareRepositoryOnly
        )
        let environment = Self.gitEnvironment(
            index: index,
            isolatedAttributes: isolatedAttributes
        )
        let finalArguments = commandArguments
        guard let gitExecutableURL else {
            throw VaultVersioningError.trustedGitUnavailable
        }
        let executablePath = gitExecutableURL.path(percentEncoded: false)
        let platformOptions = try gitPlatformOptions(
            inheritSnapshotLease: inheritSnapshotLease
        )

        let result: GitResult
        do {
            result = try await withThrowingTaskGroup(of: GitResult.self) { group in
                group.addTask {
                    let result = try await Subprocess.run(
                        .path(.init(executablePath)),
                        arguments: Arguments(finalArguments),
                        environment: environment,
                        platformOptions: platformOptions,
                        output: .string(limit: Self.maximumOutputBytes),
                        error: .string(limit: Self.maximumOutputBytes)
                    )
                    return GitResult(
                        status: result.terminationStatus,
                        standardOutput: result.standardOutput,
                        standardError: result.standardError
                    )
                }
                group.addTask {
                    try await Task.sleep(for: remaining)
                    throw GitCommandDeadlineExceeded()
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw GitCommandDeadlineExceeded()
                }
                return result
            }
        } catch is GitCommandDeadlineExceeded {
            throw VaultVersioningError.gitCommandTimedOut(arguments: arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SubprocessError
            where error.code == .spawnFailed || error.code == .executableNotFound {
            // Xcode or Command Line Tools can be replaced while the agent is
            // running. A later recovery attempt must resolve the trusted binary
            // again instead of retaining a path that can no longer launch.
            self.gitExecutableURL = nil
            didProbeGitExecutable = false
            throw VaultVersioningError.trustedGitUnavailable
        } catch {
            throw VaultVersioningError.gitCommandFailed(
                arguments: arguments,
                status: "subprocess execution failed",
                message: ""
            )
        }
        try validatePrivateDataRoot()
        return result
    }

    func gitCommandArguments(
        _ arguments: [String],
        initialization: Bool = false,
        isolatedAttributes: Bool = false,
        gitDirectory: URL? = nil,
        bareRepositoryOnly: Bool = false
    ) -> [String] {
        var commandArguments: [String] = []
        if !initialization {
            let selectedGitDirectory = gitDirectory ?? snapshotRepositoryURL
            commandArguments = [
                "--git-dir=\(selectedGitDirectory.path(percentEncoded: false))",
            ]
            if !bareRepositoryOnly {
                commandArguments.append(
                    "--work-tree=\(vaultURL.path(percentEncoded: false))"
                )
                if isolatedAttributes {
                    commandArguments.append("--attr-source=\(Self.emptyTreeObject)")
                }
                commandArguments += ["-c", "core.bare=false"]
            }
        }
        commandArguments += [
            "-c", "feature.manyFiles=false",
            "-c", "gc.auto=0",
            "-c", "maintenance.auto=0",
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false",
            "-c", "core.splitIndex=false",
            "-c", "core.untrackedCache=false",
            "-c", "core.preloadIndex=false",
            "-c", "core.sparseCheckout=false",
            "-c", "core.sparseCheckoutCone=false",
            "-c", "index.sparse=false",
            "-c", "core.filesRefLockTimeout=0",
            "-c", "core.packedRefsTimeout=0",
            "-c", "reftable.lockTimeout=0",
            "-c", "commit.gpgSign=false",
            "-c", "core.attributesFile=/dev/null",
            "-c", "core.ignoreCase=false",
            "-c", "core.precomposeUnicode=false",
            "-c", "submodule.recurse=false",
        ] + arguments
        return commandArguments
    }

    /// Keeps the OFD snapshot lease alive in a Git child if this host is
    /// killed after spawn. A replacement host therefore cannot overlap the
    /// orphaned child against the same product repository.
    func gitPlatformOptions(
        inheritSnapshotLease: Bool
    ) throws -> PlatformOptions {
        var options = PlatformOptions()
        options.processGroupID = 0
        options.teardownSequence = [
            .gracefulShutDown(
                toProcessGroup: true,
                allowedDurationToNextStep: .seconds(2)
            ),
        ]
        guard inheritSnapshotLease else { return options }
        guard let activeSnapshotLease else {
            throw VaultVersioningError.gitCommandFailed(
                arguments: [],
                status: "missing snapshot lease",
                message: ""
            )
        }
        options.preSpawnProcessConfigurator = { _, fileActions in
            try activeSnapshotLease.addChildInheritance(to: &fileActions)
        }
        return options
    }

    static func gitEnvironment(
        index: URL?,
        isolatedAttributes: Bool
    ) -> Environment {
        var values: [Environment.Key: String] = [:]
        for (key, value) in ProcessInfo.processInfo.environment
        where !key.hasPrefix("GIT_") {
            guard let environmentKey = Environment.Key(rawValue: key) else { continue }
            values[environmentKey] = value
        }
        values["GIT_TERMINAL_PROMPT"] = "0"
        values["GIT_PAGER"] = "cat"
        values["GIT_OPTIONAL_LOCKS"] = "0"
        values["GIT_NO_REPLACE_OBJECTS"] = "1"
        values["GIT_CONFIG_NOSYSTEM"] = "1"
        values["GIT_CONFIG_GLOBAL"] = "/dev/null"
        values["GIT_ATTR_NOSYSTEM"] = "1"
        values["GIT_LITERAL_PATHSPECS"] = "1"
        values["GIT_NO_LAZY_FETCH"] = "1"
        values["GIT_DEFAULT_HASH"] = "sha1"
        values["GIT_DEFAULT_REF_FORMAT"] = "files"
        values["LC_ALL"] = "C"
        if isolatedAttributes {
            values["GIT_ATTR_SOURCE"] = Self.emptyTreeObject
        }
        if let index {
            values["GIT_INDEX_FILE"] = index.path(percentEncoded: false)
        }
        return .custom(values)
    }

    func requireSuccess(
        _ arguments: [String],
        index: URL? = nil,
        deadline: ContinuousClock.Instant,
        initialization: Bool = false,
        inheritSnapshotLease: Bool = false
    ) async throws {
        let result = try await executeGit(
            arguments,
            index: index,
            deadline: deadline,
            initialization: initialization,
            inheritSnapshotLease: inheritSnapshotLease
        )
        guard result.status.isSuccess else {
            throw commandFailure(arguments: arguments, result: result)
        }
    }

    func requireOutput(
        _ arguments: [String],
        index: URL? = nil,
        deadline: ContinuousClock.Instant
    ) async throws -> String {
        let result = try await executeGit(
            arguments,
            index: index,
            deadline: deadline
        )
        guard result.status.isSuccess else {
            throw commandFailure(arguments: arguments, result: result)
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func invalidSnapshotState(arguments: [String]) -> VaultVersioningError {
        .gitCommandFailed(
            arguments: arguments,
            status: "invalid private snapshot reference",
            message: ""
        )
    }

    func commandFailure(arguments: [String], result: GitResult) -> VaultVersioningError {
        .gitCommandFailed(
            arguments: arguments,
            status: result.status.description,
            message: result.standardError
        )
    }
}

/// Resolves only a canonical regular executable satisfying Apple's Git code
/// requirement. `/usr/bin/git` is deliberately absent because it is an
/// xcode-select shim with a different designated identity.
struct AppleGitExecutable {
    private static let requirementText = #"identifier "com.apple.git" and anchor apple"#

    static func resolve(
        locator: () -> URL? = { locate() }
    ) throws -> URL {
        guard let resolved = locator(), isTrusted(resolved) else {
            throw VaultVersioningError.trustedGitUnavailable
        }
        return resolved
    }

    static func isTrusted(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path != "/usr/bin/git" else { return false }
        var metadata = stat()
        guard Darwin.lstat(canonical.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              Darwin.access(canonical.path, X_OK) == 0 else {
            return false
        }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            canonical as CFURL,
            SecCSFlags(),
            &code
        ) == errSecSuccess, let code else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess, let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(
            code,
            SecCSFlags(),
            requirement
        ) == errSecSuccess
    }

    private static func locate() -> URL? {
        var candidates: [URL] = []
        if let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           !developerDirectory.isEmpty {
            candidates.append(
                URL(fileURLWithPath: developerDirectory, isDirectory: true)
                    .appendingPathComponent("usr/bin/git")
            )
        }
        candidates += [
            URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git"),
            URL(fileURLWithPath: "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/git"),
            URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/bin/git"),
        ]
        if let applications = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications", isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates += applications
                .filter { $0.pathExtension.lowercased() == "app" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map {
                    $0.appendingPathComponent("Contents/Developer/usr/bin/git")
                }
        }

        var visited: Set<String> = []
        for candidate in candidates {
            let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard visited.insert(canonical.path).inserted else { continue }
            if isTrusted(canonical) { return canonical }
        }
        return nil
    }
}

/// Stable identity of the directory authorized as this runtime's vault root.
private struct VaultRootIdentity: Sendable {
    let device: dev_t
    let inode: ino_t

    static func capture(_ url: URL) throws -> Self {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw VaultVersioningError.invalidRepositoryURL
        }
        return Self(device: metadata.st_dev, inode: metadata.st_ino)
    }

    func matches(_ url: URL) -> Bool {
        var metadata = stat()
        return Darwin.lstat(url.path, &metadata) == 0
            && matches(metadata)
    }

    func matches(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFDIR
            && metadata.st_dev == device
            && metadata.st_ino == inode
    }
}

/// Opens the persistent snapshot lock strictly below the captured private data
/// root. Every pathname component after the root is descriptor-relative and
/// no-follow, so replacing an ancestor cannot create a file outside that root.
private enum PrivateSnapshotLockFile {
    static func open(
        rootURL: URL,
        rootIdentity: VaultRootIdentity,
        directoryName: String,
        directoryIdentity: VaultRootIdentity,
        fileName: String
    ) throws -> Int32 {
        let rootDescriptor = Darwin.open(
            rootURL.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            throw VaultVersioningError.invalidPrivateRepository
        }
        defer { Darwin.close(rootDescriptor) }
        var rootMetadata = stat()
        guard Darwin.fstat(rootDescriptor, &rootMetadata) == 0,
              rootIdentity.matches(rootMetadata) else {
            throw VaultVersioningError.invalidPrivateRepository
        }

        let directoryDescriptor = Darwin.openat(
            rootDescriptor,
            directoryName,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw VaultVersioningError.invalidPrivateRepository
        }
        defer { Darwin.close(directoryDescriptor) }
        var directoryMetadata = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryMetadata) == 0,
              directoryIdentity.matches(directoryMetadata) else {
            throw VaultVersioningError.invalidPrivateRepository
        }

        let lockDescriptor = Darwin.openat(
            directoryDescriptor,
            fileName,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard lockDescriptor >= 0 else {
            throw VaultVersioningError.invalidPrivateRepository
        }
        return lockDescriptor
    }
}

/// UUID-named 0700 storage for one isolated index. Stale owned directories are
/// conservatively scavenged and can never alias a later transaction.
struct GitSnapshotIndexWorkspace {
    private static let prefix = "SecondBrainMCP-snapshot-index-"
    private static let staleAge: TimeInterval = 24 * 60 * 60
    private static let maximumScavengeEntries = 1_024
    private static let deadlineArguments = ["snapshot-workspace-scavenge"]

    let directory: URL
    let file: URL
    private let directoryIdentity: VaultRootIdentity

    static func create(
        in root: URL,
        deadline: ContinuousClock.Instant
    ) throws -> Self {
        try scavenge(in: root, deadline: deadline)
        try checkAdmission(deadline: deadline)
        let directory = root.appendingPathComponent(
            prefix + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try checkAdmission(deadline: deadline)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        var metadata = stat()
        guard Darwin.lstat(directory.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & 0o777 == 0o700 else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteNoPermission)
        }
        return Self(
            directory: directory,
            file: directory.appendingPathComponent("index"),
            directoryIdentity: VaultRootIdentity(
                device: metadata.st_dev,
                inode: metadata.st_ino
            )
        )
    }

    func remove() {
        guard directoryIdentity.matches(directory) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func scavenge(
        in root: URL,
        deadline: ContinuousClock.Instant
    ) throws {
        try checkAdmission(deadline: deadline)
        let errors = WorkspaceEnumerationErrors()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                errors.mark()
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        var scannedEntries = 0
        while scannedEntries < maximumScavengeEntries {
            try checkAdmission(deadline: deadline)
            guard let candidate = enumerator.nextObject() as? URL else { break }
            try checkAdmission(deadline: deadline)
            scannedEntries += 1
            let name = candidate.lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            guard UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            var metadata = stat()
            guard Darwin.lstat(candidate.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == Darwin.geteuid(),
                  metadata.st_mode & 0o777 == 0o700 else { continue }
            let modified = Date(
                timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
            )
            if Date().timeIntervalSince(modified) >= staleAge {
                try? FileManager.default.removeItem(at: candidate)
                try checkAdmission(deadline: deadline)
            }
        }
        guard !errors.encountered else { throw CocoaError(.fileReadUnknown) }
    }

    private static func checkAdmission(
        deadline: ContinuousClock.Instant
    ) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw VaultVersioningError.gitCommandTimedOut(
                arguments: deadlineArguments
            )
        }
    }

    private final class WorkspaceEnumerationErrors: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var encountered: Bool {
            lock.withLock { value }
        }

        func mark() {
            lock.withLock { value = true }
        }
    }
}
