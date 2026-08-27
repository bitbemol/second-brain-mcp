import CryptoKit
import Darwin
import Foundation

/// A flat, request-owned immutable spool. Its source work budget is never refunded.
actor SearchCaptureSession {
    struct Entry: Sendable {
        let target: ReadableFileTarget
        let revision: FileRevision
        let modifiedDate: Date?
        let byteCount: Int
        var path: String { target.relativePath }
        var format: FileFormat { target.format }
        fileprivate let name: String
        fileprivate let owner: UUID
    }

    private let directory: SearchCaptureDirectory
    private let vaultRoot: URL
    private let observer: (@Sendable (ReadableFileTarget) -> Void)?
    private let snapshotLoadObserver: (@Sendable (Int) -> Void)?
    private let limits: SearchCaptureLimits
    private let identity = UUID()
    private var descriptor: Int32
    private var attemptedBytes = 0
    private var attemptedFiles = 0
    private var manifestBytes = 0

    init(
        directory: SearchCaptureDirectory,
        vaultRoot: URL,
        observer: (@Sendable (ReadableFileTarget) -> Void)?,
        snapshotLoadObserver: (@Sendable (Int) -> Void)? = nil,
        limits: SearchCaptureLimits
    ) throws {
        self.directory = directory
        self.vaultRoot = vaultRoot
        self.observer = observer
        self.snapshotLoadObserver = snapshotLoadObserver
        self.limits = limits
        self.descriptor = try directory.createCapture()
    }

    /// Shared accounting for retained capture metadata, excluding source payload bytes.
    static func manifestEntryBytes(relativePath: String, absolutePath: String, format: FileFormat) -> Int {
        relativePath.utf8.count + absolutePath.utf8.count + format.rawValue.utf8.count + 71
    }

    func capture(_ target: ReadableFileTarget) throws -> Entry {
        try Task.checkCancellation()
        guard descriptor >= 0 else { throw SearchCaptureStorageError() }
        let metadataBytes = Self.manifestEntryBytes(
            relativePath: target.relativePath, absolutePath: target.url.path, format: target.format
        )
        guard attemptedFiles < limits.maximumFiles,
              metadataBytes <= limits.maximumManifestBytes - manifestBytes else {
            throw VaultSearchRequestError.workBudgetExceeded
        }
        let name = String(format: "%08d.capture", attemptedFiles)
        attemptedFiles += 1
        manifestBytes += metadataBytes
        let remaining = limits.maximumBytes - attemptedBytes
        // A zero-byte source still fits an exactly exhausted byte budget; the
        // stable descriptor's initial size check rejects any non-empty source.
        guard remaining >= 0 else { throw VaultSearchRequestError.workBudgetExceeded }
        let maximumBytes = min(target.format.maximumFileBytes, remaining)
        try target.revalidate()
        var output: Int32 = -1
        var created = false
        do {
            let copied = try BoundedFileReader.withStableFileDescriptor(
                fromCanonical: target.url,
                maximumBytes: maximumBytes,
                path: target.relativePath,
                rejectHiddenDescendantsOf: vaultRoot
            ) { source, initialBytes -> (Int, FileRevision) in
                observer?(target)
                output = Darwin.openat(
                    descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
                )
                guard output >= 0 else { throw SearchCaptureStorageError() }
                created = true
                var hasher = SHA256()
                var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
                var copiedBytes = 0
                // The stable descriptor's final fingerprint rejects growth/truncation;
                // no extra byte beyond the aggregate source ceiling is needed.
                while copiedBytes < initialBytes {
                    try Task.checkCancellation()
                    let requested = min(buffer.count, initialBytes - copiedBytes)
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(source, $0.baseAddress, requested)
                    }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    guard count > 0 else { throw BoundedFileReader.ReadError.changedDuringRead }
                    attemptedBytes += count
                    guard attemptedBytes <= limits.maximumBytes else {
                        throw VaultSearchRequestError.workBudgetExceeded
                    }
                    copiedBytes += count
                    try buffer.withUnsafeBytes { raw in
                        let bytes = UnsafeRawBufferPointer(rebasing: raw[..<count])
                        hasher.update(bufferPointer: bytes)
                        var written = 0
                        while written < count {
                            try Task.checkCancellation()
                            let amount = Darwin.write(output, bytes.baseAddress!.advanced(by: written), count - written)
                            if amount < 0, errno == EINTR { continue }
                            guard amount > 0 else { throw SearchCaptureStorageError() }
                            written += amount
                        }
                    }
                }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                return (copiedBytes, FileRevision(validatedSHA256Hex: digest))
            }
            guard Darwin.close(output) == 0 else {
                output = -1
                throw SearchCaptureStorageError()
            }
            output = -1
            return Entry(
                target: target, revision: copied.value.1,
                modifiedDate: copied.metadata.modificationDate, byteCount: copied.value.0,
                name: name, owner: identity
            )
        } catch {
            if output >= 0 { Darwin.close(output) }
            if created, Darwin.unlinkat(descriptor, name, 0) != 0 {
                throw SearchCaptureStorageError()
            }
            if let violation = error as? FileResourcePolicy.Violation,
               violation.bytes <= target.format.maximumFileBytes,
               remaining < target.format.maximumFileBytes {
                throw VaultSearchRequestError.workBudgetExceeded
            }
            throw error
        }
    }

    /// Reads only the anchored private spool and verifies size and exact raw revision.
    func snapshot(_ entry: Entry) throws -> FileSnapshot {
        try Task.checkCancellation()
        guard descriptor >= 0, entry.owner == identity else { throw SearchCaptureStorageError() }
        let source = Darwin.openat(
            descriptor, entry.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard source >= 0 else { throw SearchCaptureStorageError() }
        defer { Darwin.close(source) }
        var metadata = stat()
        guard Darwin.fstat(source, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              metadata.st_size == entry.byteCount else { throw SearchCaptureStorageError() }
        // Records the admitted private-source materialization immediately before allocation.
        snapshotLoadObserver?(entry.byteCount)
        var bytes = Data()
        bytes.reserveCapacity(entry.byteCount)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while bytes.count < entry.byteCount {
            try Task.checkCancellation()
            let requested = min(buffer.count, entry.byteCount - bytes.count)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(source, $0.baseAddress, requested)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw SearchCaptureStorageError() }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var final = stat()
        guard Darwin.fstat(source, &final) == 0, final.st_size == entry.byteCount,
              final.st_ino == metadata.st_ino, final.st_dev == metadata.st_dev else {
            throw SearchCaptureStorageError()
        }
        let snapshot = FileSnapshot(data: bytes, modifiedDate: entry.modifiedDate)
        guard snapshot.revision == entry.revision else { throw SearchCaptureStorageError() }
        return snapshot
    }

    /// Cleanup must finish even when the owning task is canceled.
    func close() throws {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        try directory.removeAbandonedCapture()
    }
}
