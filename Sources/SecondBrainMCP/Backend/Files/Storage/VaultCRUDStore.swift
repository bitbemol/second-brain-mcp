import Foundation

/// The only component that mutates first-class files managed by the generic API.
/// Format handlers prepare bytes; this actor owns atomic persistence and soft-delete.
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
        let metadata = try VaultFileInspector.inspect(target)
        try FileResourcePolicy.validate(
            bytes: metadata.byteCount,
            format: target.format,
            path: target.relativePath
        )
        let data = try BoundedFileReader.read(
            from: target.url,
            maximumBytes: target.format.maximumFileBytes,
            path: target.relativePath
        )
        return FileSnapshot(
            data: data,
            modifiedDate: metadata.modificationDate
        )
    }

    /// Atomically creates a new file without clobbering an existing destination.
    ///
    /// - Parameters:
    ///   - target: Structurally writable target under `notes/`.
    ///   - data: Fully prepared bytes from a format handler.
    /// - Throws: ``StoreError/alreadyExists(_:)``, ``FileResourcePolicy/Violation``,
    ///   or a filesystem error.
    func create(target: WritableFileTarget, data: Data) throws {
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
    ///   - expected: Snapshot captured before format-specific preparation.
    /// - Throws: ``StoreError/changedSinceRead(_:)`` if an external edit won the
    ///   race, or ``FileResourcePolicy/Violation`` when replacement data is too large.
    func replace(target: WritableFileTarget, data: Data, expected: FileSnapshot) throws {
        try FileResourcePolicy.validate(
            bytes: data.count,
            format: target.format,
            path: target.relativePath
        )
        let current = try snapshot(target.readable)
        guard current.data == expected.data else {
            throw StoreError.changedSinceRead(target.relativePath)
        }
        try data.write(to: target.url, options: .atomic)
    }

    /// Moves a file to a collision-proof recoverable path under `.trash/`.
    ///
    /// - Parameter target: Structurally writable target under `notes/`.
    /// - Returns: Vault-relative trash path.
    /// - Throws: ``VaultFileInspector/InspectionError`` or a filesystem move error.
    func softDelete(target: WritableFileTarget) throws -> String {
        let fm = FileManager.default
        _ = try VaultFileInspector.inspect(target.readable)

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
        return ".trash/\(destination.lastPathComponent)"
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
