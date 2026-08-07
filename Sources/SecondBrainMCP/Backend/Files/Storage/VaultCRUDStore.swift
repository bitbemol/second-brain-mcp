import Foundation

/// The only component that mutates first-class files managed by the generic API.
/// Format handlers prepare bytes; this actor owns atomic persistence and soft-delete.
///
/// Caller revisions and path leases provide compare-and-swap semantics among
/// cooperating MCP runtimes. An unrelated application does not honor those
/// leases and can still write during the final compare-to-rename filesystem
/// window; no pathname API supplies a universal cross-application CAS.
actor VaultCRUDStore {

    /// Persistence failures independent of concrete file-format semantics.
    enum StoreError: Error, CustomStringConvertible {
        /// Creation would overwrite an existing destination.
        case alreadyExists(String)
        /// Current bytes differ from the snapshot used to prepare an update.
        case changedSinceRead(String)
        /// The process trash path is not a real directory inside the vault.
        case unsafeTrashDirectory(String)
        /// Human-readable generic persistence failure.
        var description: String {
            switch self {
            case .alreadyExists(let path): return "File already exists: \(path)"
            case .changedSinceRead(let path): return "File changed while the update was being prepared: \(path)"
            case .unsafeTrashDirectory(let path): return "Vault trash path is not a safe directory: \(path)"
            }
        }
    }

    private let vaultPath: String

    /// Creates a store rooted at one vault.
    ///
    /// - Parameter vaultPath: Canonical vault root.
    init(vaultPath: String) {
        self.vaultPath = vaultPath
    }

    /// Reads immutable bytes and modification metadata for optimistic updates.
    ///
    /// - Parameters:
    ///   - target: Validated readable target.
    /// - Returns: A snapshot used for reads or compare-before-replace updates.
    /// - Throws: ``VaultFileInspector/InspectionError``,
    ///   ``FileResourcePolicy/Violation``, or a filesystem read error.
    func snapshot(_ target: ReadableFileTarget) throws -> FileSnapshot {
        try snapshot(target, maximumBytes: target.format.maximumFileBytes)
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
    func snapshot(
        _ target: ReadableFileTarget,
        maximumBytes: Int
    ) throws -> FileSnapshot {
        let effectiveLimit = min(target.format.maximumFileBytes, maximumBytes)
        let opened = try VaultFileInspector.snapshot(
            target,
            maximumBytes: effectiveLimit,
        )
        return FileSnapshot(
            data: opened.data,
            modifiedDate: opened.metadata.modificationDate
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
        let fm = FileManager.default
        try target.revalidate()
        try FileResourcePolicy.validate(
            bytes: data.count,
            format: target.format,
            path: target.relativePath
        )
        guard !fm.fileExists(atPath: target.url.path) else {
            throw StoreError.alreadyExists(target.relativePath)
        }
        try fm.createDirectory(
            at: target.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Write a sibling temporary file, then atomically move it into place.
        // moveItem refuses an existing destination, preserving no-clobber even
        // if an external editor wins the race after the check above.
        let temporary = target.url.deletingLastPathComponent()
            .appendingPathComponent(".secondbrain-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            try fm.moveItem(at: temporary, to: target.url)
            return FileSnapshot(data: data, modifiedDate: nil).revision
        } catch {
            try? fm.removeItem(at: temporary)
            if fm.fileExists(atPath: target.url.path) {
                throw StoreError.alreadyExists(target.relativePath)
            }
            throw error
        }
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
        let current = try snapshot(target.readable)
        guard current.revision == expectedRevision else {
            throw StoreError.changedSinceRead(target.relativePath)
        }
        try data.write(to: target.url, options: .atomic)
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
        let fm = FileManager.default
        // Capture and compare the bytes immediately before the move. This makes
        // deletion use the same compare-and-swap contract as replacement rather
        // than deleting whichever version happens to occupy the path now.
        let current = try snapshot(target.readable)
        guard current.revision == expectedRevision else {
            throw StoreError.changedSinceRead(target.relativePath)
        }

        let canonicalVault = URL(fileURLWithPath: vaultPath)
            .standardized
            .resolvingSymlinksInPath()
        let trashURL = canonicalVault.appendingPathComponent(".trash", isDirectory: true)
        guard !PathValidator.containsSymbolicLinkComponent(
            relativePath: ".trash",
            root: canonicalVault.path
        ) else {
            throw StoreError.unsafeTrashDirectory(trashURL.path)
        }
        try fm.createDirectory(at: trashURL, withIntermediateDirectories: true)
        guard !PathValidator.containsSymbolicLinkComponent(
            relativePath: ".trash",
            root: canonicalVault.path
        ),
              let attributes = try? fm.attributesOfItem(atPath: trashURL.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw StoreError.unsafeTrashDirectory(trashURL.path)
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        // The UUID prevents same-second collisions for equal basenames from
        // different folders, while retaining the original name for recovery.
        let destination = trashURL.appendingPathComponent(
            "\(timestamp)_\(UUID().uuidString)_\(target.url.lastPathComponent)"
        )
        try fm.moveItem(at: target.url, to: destination)
        cleanupEmptyDirectories(from: target.url.deletingLastPathComponent())
        return (
            ".trash/\(destination.lastPathComponent)",
            current.revision
        )
    }

    private func cleanupEmptyDirectories(from startingURL: URL) {
        let notesURL = URL(fileURLWithPath: vaultPath).appendingPathComponent("notes", isDirectory: true)
        var directory = startingURL
        let fm = FileManager.default

        while directory.path != notesURL.path && directory.path.hasPrefix(notesURL.path + "/") {
            let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? ["occupied"]
            let meaningful = contents.filter { $0 != ".DS_Store" }
            guard meaningful.isEmpty else { break }
            try? fm.removeItem(at: directory)
            directory.deleteLastPathComponent()
        }
    }
}
