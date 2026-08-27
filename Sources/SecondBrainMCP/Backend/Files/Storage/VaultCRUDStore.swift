import Foundation

/// The only component that mutates first-class files managed by the generic API.
/// Format handlers prepare bytes; this actor owns atomic persistence and soft-delete.
///
/// Caller revisions and path leases provide compare-and-swap semantics among
/// cooperating MCP runtimes. An unrelated application does not honor those
/// leases and can still write during the final compare-to-rename filesystem
/// window; no pathname API supplies a universal cross-application CAS.
actor VaultCRUDStore {
    typealias SnapshotLoader = @Sendable (
        ReadableFileTarget,
        Int,
        URL?,
        BoundedFileReader.ReadObserver?
    ) throws -> BoundedFileReader.Snapshot

    /// Persistence failures independent of concrete file-format semantics.
    enum StoreError: Error, CustomStringConvertible, CallerSafeError {
        /// Creation would overwrite an existing destination.
        case alreadyExists(String)
        /// Current bytes differ from the snapshot used to prepare an update.
        case changedSinceRead(String)
        /// The process trash path is not a real directory inside the vault.
        case unsafeTrashDirectory(String)
        /// No caller path or internal trash location crosses the tool boundary.
        var callerSafeDescription: String {
            switch self {
            case .alreadyExists:
                "File already exists; inspect it before updating, or choose an unused destination."
            case .changedSinceRead:
                "File changed while the operation was prepared; read its current revision before retrying."
            case .unsafeTrashDirectory:
                "Vault trash directory is unsafe; ask the vault owner to repair it before deleting files."
            }
        }

        /// Human-readable generic persistence failure.
        var description: String {
            switch self {
            case .alreadyExists(let path): return "File already exists: \(path)"
            case .changedSinceRead(let path): return "File changed while the update was being prepared: \(path)"
            case .unsafeTrashDirectory(let path): return "Vault trash path is not a safe directory: \(path)"
            }
        }
    }

    private nonisolated let vaultPath: String
    private nonisolated let snapshotLoader: SnapshotLoader
    private let persistence: VaultDescriptorPersistence

    /// Creates a store rooted at one vault.
    ///
    /// - Parameters:
    ///   - vaultPath: Canonical vault root.
    ///   - snapshotLoader: Stable descriptor reader, injectable for concurrency tests.
    ///   - beforePersistence: Test barrier after opening commit descriptors.
    init(
        vaultPath: String,
        snapshotLoader: @escaping SnapshotLoader = {
            try VaultFileInspector.snapshot(
                $0,
                maximumBytes: $1,
                rejectHiddenDescendantsOf: $2,
                didReadBytes: $3
            )
        },
        beforePersistence: (@Sendable () throws -> Void)? = nil
    ) {
        self.vaultPath = vaultPath
        self.snapshotLoader = snapshotLoader
        self.persistence = VaultDescriptorPersistence(vaultPath: vaultPath, beforeCommit: beforePersistence)
    }

    /// Reads immutable bytes and modification metadata for optimistic updates.
    ///
    /// - Parameters:
    ///   - target: Validated readable target.
    /// - Returns: A snapshot used for reads or compare-before-replace updates.
    /// - Throws: ``VaultFileInspector/InspectionError``,
    ///   ``FileResourcePolicy/Violation``, or a filesystem read error.
    nonisolated func snapshot(
        _ target: ReadableFileTarget
    ) async throws -> FileSnapshot {
        try loadSnapshot(
            target,
            maximumBytes: target.format.maximumFileBytes
        )
    }

    /// Reads a snapshot through a caller-supplied stricter byte ceiling.
    ///
    /// The effective limit can only narrow the format policy. Search uses this
    /// to ensure a file that grows after metadata inspection cannot allocate
    /// beyond the remaining whole-request corpus budget.
    ///
    /// - Parameters:
    ///   - target: Validated readable target.
    ///   - maximumBytes: Additional nonnegative ceiling for this one read.
    /// - Returns: Complete bytes and modification metadata within both limits.
    /// - Throws: ``VaultFileInspector/InspectionError``,
    ///   ``FileResourcePolicy/Violation``, or a filesystem read error.
    nonisolated func snapshot(
        _ target: ReadableFileTarget,
        maximumBytes: Int,
        rejectHiddenComponents: Bool = false,
        didReadBytes: BoundedFileReader.ReadObserver? = nil
    ) async throws -> FileSnapshot {
        try loadSnapshot(
            target,
            maximumBytes: maximumBytes,
            rejectHiddenComponents: rejectHiddenComponents,
            didReadBytes: didReadBytes
        )
    }

    private nonisolated func loadSnapshot(
        _ target: ReadableFileTarget,
        maximumBytes: Int,
        rejectHiddenComponents: Bool = false,
        didReadBytes: BoundedFileReader.ReadObserver? = nil
    ) throws -> FileSnapshot {
        let opened = try loadRawSnapshot(
            target, maximumBytes: maximumBytes, rejectHiddenComponents: rejectHiddenComponents,
            didReadBytes: didReadBytes
        )
        return FileSnapshot(
            data: opened.data,
            modifiedDate: opened.metadata.modificationDate
        )
    }

    private nonisolated func loadRawSnapshot(
        _ target: ReadableFileTarget,
        maximumBytes: Int,
        rejectHiddenComponents: Bool = false,
        didReadBytes: BoundedFileReader.ReadObserver? = nil
    ) throws -> BoundedFileReader.Snapshot {
        try snapshotLoader(
            target,
            min(target.format.maximumFileBytes, maximumBytes),
            rejectHiddenComponents ? URL(fileURLWithPath: vaultPath) : nil,
            didReadBytes
        )
    }

    /// Confirms a create destination is still absent before durable intent.
    ///
    /// ``create(target:data:)`` repeats this check and retains its atomic
    /// no-clobber move. This earlier validation keeps an ordinary existing-file
    /// rejection outside the mutation executor's point of no return.
    func requireAbsent(_ target: WritableFileTarget) throws {
        try target.revalidate()
        guard !FileManager.default.fileExists(atPath: target.url.path) else {
            throw StoreError.alreadyExists(target.relativePath)
        }
    }

    /// Atomically creates a new file without clobbering an existing destination.
    ///
    /// - Parameters:
    ///   - target: Structurally writable target under `notes/`.
    ///   - data: Fully prepared bytes from a format handler.
    /// - Returns: Revision of the exact bytes created.
    /// - Throws: ``StoreError/alreadyExists(_:)``, ``FileResourcePolicy/Violation``,
    ///   or a filesystem error.
    @discardableResult
    func create(target: WritableFileTarget, data: Data) throws -> FileRevision {
        try target.revalidate()
        try FileResourcePolicy.validate(
            bytes: data.count,
            format: target.format,
            path: target.relativePath
        )
        try persistence.write(data, to: target)
        return FileSnapshot(data: data, modifiedDate: nil).revision
    }

    /// Atomically replaces a file only when its bytes still match a snapshot.
    ///
    /// - Parameters:
    ///   - target: Structurally writable target under `notes/`.
    ///   - data: Fully prepared replacement bytes.
    ///   - expectedRevision: Caller revision that must still identify the file.
    /// - Returns: Revision of the exact replacement bytes.
    /// - Throws: ``StoreError/changedSinceRead(_:)`` if an external edit won the
    ///   race, or ``FileResourcePolicy/Violation`` when replacement data is too large.
    @discardableResult
    func replace(
        target: WritableFileTarget,
        data: Data,
        expectedRevision: FileRevision
    ) throws -> FileRevision {
        try FileResourcePolicy.validate(
            bytes: data.count,
            format: target.format,
            path: target.relativePath
        )
        let current = try loadRawSnapshot(
            target.readable,
            maximumBytes: target.format.maximumFileBytes
        )
        let revision = FileSnapshot(data: current.data, modifiedDate: current.metadata.modificationDate).revision
        guard revision == expectedRevision else {
            throw StoreError.changedSinceRead(target.relativePath)
        }
        try persistence.write(data, to: target, replacing: current.metadata)
        return FileSnapshot(data: data, modifiedDate: nil).revision
    }

    /// Moves a file to a collision-proof recoverable path under `.trash/`.
    ///
    /// - Parameters:
    ///   - target: Structurally writable target under `notes/`.
    ///   - expectedRevision: Caller revision that must still identify the file.
    /// - Returns: Vault-relative trash path and the revision that was removed.
    /// - Throws: ``VaultFileInspector/InspectionError`` or a filesystem move error.
    func softDelete(
        target: WritableFileTarget,
        expectedRevision: FileRevision
    ) throws -> (trashPath: String, deletedRevision: FileRevision) {
        let current = try loadRawSnapshot(
            target.readable,
            maximumBytes: target.format.maximumFileBytes
        )
        let revision = FileSnapshot(data: current.data, modifiedDate: current.metadata.modificationDate).revision
        guard revision == expectedRevision else {
            throw StoreError.changedSinceRead(target.relativePath)
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "\(timestamp)_\(UUID().uuidString)_\(target.url.lastPathComponent)"
        try persistence.moveToTrash(target, expected: current.metadata, name: name)
        return (".trash/\(name)", revision)
    }
}
