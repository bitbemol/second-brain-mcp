import CryptoKit
import Darwin
import Foundation

/// Private immutable vault-file copy for frameworks that reopen pathnames.
struct VaultTemporaryFileSnapshot: Sendable {
    let url: URL
    let byteCount: Int
    let metadata: RegularFileMetadata
    let revision: FileRevision
    private let directoryURL: URL

    fileprivate init(
        url: URL,
        byteCount: Int,
        metadata: RegularFileMetadata,
        revision: FileRevision,
        directoryURL: URL
    ) {
        self.url = url
        self.byteCount = byteCount
        self.metadata = metadata
        self.revision = revision
        self.directoryURL = directoryURL
    }

    /// Removes the process-owned snapshot after the framework operation.
    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

/// Single filesystem trust boundary for already validated vault targets.
///
/// Path targets prove containment and extension agreement; this inspector proves
/// that the resolved entry currently exists and is a regular file before any
/// generic or format-specific reader opens it.
enum VaultFileInspector {
    /// Failures raised while inspecting a validated vault target.
    enum InspectionError: Error, CustomStringConvertible, Sendable {
        /// No filesystem entry exists at the target path.
        case notFound(String)
        /// The target exists but is not a regular file.
        case notARegularFile(String)

        /// Human-readable inspection failure.
        var description: String {
            switch self {
            case .notFound(let path):
                "File not found: \(path)"
            case .notARegularFile(let path):
                "Path is not a regular file: \(path)"
            }
        }
    }

    /// Inspects the current filesystem entry for a validated target.
    ///
    /// - Parameter target: Contained, extension-checked vault target.
    /// - Returns: Immutable metadata for the regular file.
    /// - Throws: ``InspectionError`` or a filesystem metadata error.
    static func inspect(_ target: ReadableFileTarget) throws -> RegularFileMetadata {
        try target.revalidate()
        do {
            return try RegularFileInspector.inspect(target.url)
        } catch RegularFileInspector.InspectionError.notFound {
            throw InspectionError.notFound(target.relativePath)
        } catch RegularFileInspector.InspectionError.notARegularFile {
            throw InspectionError.notARegularFile(target.relativePath)
        }
    }

    /// Opens and snapshots a contained target through one stable descriptor.
    static func snapshot(
        _ target: ReadableFileTarget,
        maximumBytes: Int,
        rejectHiddenDescendantsOf protectedRoot: URL? = nil
    ) throws -> BoundedFileReader.Snapshot {
        try target.revalidate()
        do {
            return try BoundedFileReader.snapshot(
                fromCanonical: target.url,
                maximumBytes: maximumBytes,
                path: target.relativePath,
                rejectHiddenDescendantsOf: protectedRoot
            )
        } catch BoundedFileReader.ReadError.notFound {
            throw InspectionError.notFound(target.relativePath)
        } catch BoundedFileReader.ReadError.notARegularFile {
            throw InspectionError.notARegularFile(target.relativePath)
        } catch BoundedFileReader.ReadError.hiddenComponent {
            throw InspectionError.notARegularFile(target.relativePath)
        }
    }

    /// Validates an opened target and its vault descendants without reading bytes.
    static func validateSearchableDescriptor(
        _ target: ReadableFileTarget,
        vaultRoot: URL
    ) throws {
        try target.revalidate()
        do {
            _ = try BoundedFileReader.withStableFileDescriptor(
                fromCanonical: target.url,
                maximumBytes: Int.max,
                path: target.relativePath,
                rejectHiddenDescendantsOf: vaultRoot
            ) { _, _ in () }
        } catch BoundedFileReader.ReadError.notFound {
            throw InspectionError.notFound(target.relativePath)
        } catch BoundedFileReader.ReadError.notARegularFile,
                BoundedFileReader.ReadError.hiddenComponent {
            throw InspectionError.notARegularFile(target.relativePath)
        }
    }

    /// Returns descriptor-bound metadata without reading file bytes.
    static func stableMetadata(
        _ target: ReadableFileTarget,
        vaultRoot: URL
    ) throws -> RegularFileMetadata {
        try target.revalidate()
        do {
            return try BoundedFileReader.withStableFileDescriptor(
                fromCanonical: target.url,
                maximumBytes: target.format.maximumFileBytes,
                path: target.relativePath,
                rejectHiddenDescendantsOf: vaultRoot
            ) { _, _ in () }.metadata
        } catch BoundedFileReader.ReadError.notFound {
            throw InspectionError.notFound(target.relativePath)
        } catch BoundedFileReader.ReadError.notARegularFile,
                BoundedFileReader.ReadError.hiddenComponent {
            throw InspectionError.notARegularFile(target.relativePath)
        }
    }

    /// Streams one stable descriptor into private storage for URL-only decoders.
    static func temporarySnapshot(
        _ target: ReadableFileTarget,
        maximumBytes: Int
    ) throws -> VaultTemporaryFileSnapshot {
        try target.revalidate()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainMCP-vault-\(UUID().uuidString)")
        let filename = "snapshot.\(target.url.pathExtension)"
        let snapshotURL = directoryURL.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard FileManager.default.createFile(
                atPath: snapshotURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: snapshotURL)
            defer { try? output.close() }
            let copied = try BoundedFileReader.withStableFileDescriptor(
                fromCanonical: target.url,
                maximumBytes: maximumBytes,
                path: target.relativePath
            ) { descriptor, _ in
                var copiedBytes = 0
                var digest = SHA256()
                var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                while true {
                    try Task.checkCancellation()
                    let remaining = maximumBytes - copiedBytes
                    let requested = min(buffer.count, max(remaining, 1))
                    let count = buffer.withUnsafeMutableBytes { bytes in
                        Darwin.read(descriptor, bytes.baseAddress, requested)
                    }
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    copiedBytes += count
                    guard copiedBytes <= maximumBytes else {
                        throw FileResourcePolicy.Violation(
                            path: target.relativePath,
                            bytes: copiedBytes,
                            limit: maximumBytes
                        )
                    }
                    let chunk = Data(buffer.prefix(count))
                    digest.update(data: chunk)
                    try output.write(contentsOf: chunk)
                }
                return (copiedBytes, digest.finalize())
            }
            guard copied.value.0 == copied.metadata.byteCount else {
                throw BoundedFileReader.ReadError.changedDuringRead
            }
            let digest = copied.value.1.map { String(format: "%02x", $0) }.joined()
            return VaultTemporaryFileSnapshot(
                url: snapshotURL,
                byteCount: copied.value.0,
                metadata: copied.metadata,
                revision: FileRevision(validatedSHA256Hex: digest),
                directoryURL: directoryURL
            )
        } catch BoundedFileReader.ReadError.notFound {
            try? FileManager.default.removeItem(at: directoryURL)
            throw InspectionError.notFound(target.relativePath)
        } catch BoundedFileReader.ReadError.notARegularFile {
            try? FileManager.default.removeItem(at: directoryURL)
            throw InspectionError.notARegularFile(target.relativePath)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }
}
