import Foundation

/// Private immutable vault-file copy for frameworks that require a URL.
struct VaultTemporaryFileSnapshot: Sendable {
    let url: URL
    let byteCount: Int
    private let directoryURL: URL

    fileprivate init(
        url: URL,
        byteCount: Int,
        directoryURL: URL
    ) {
        self.url = url
        self.byteCount = byteCount
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
    enum InspectionError: Error, CustomStringConvertible, CallerSafeError, Sendable {
        /// No filesystem entry exists at the target path.
        case notFound(String)
        /// The target exists but is not a regular file.
        case notARegularFile(String)

        /// File identities stay private; missing paths are not successful empty reads.
        var callerSafeDescription: String {
            switch self {
            case .notFound:
                "File not found; use list_files or the destination returned by move_path to locate its current path."
            case .notARegularFile:
                "Path is not a regular file; choose a supported file from list_files."
            }
        }

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
        rejectHiddenDescendantsOf protectedRoot: URL? = nil,
        didReadBytes: BoundedFileReader.ReadObserver? = nil
    ) throws -> BoundedFileReader.Snapshot {
        try target.revalidate()
        do {
            return try BoundedFileReader.snapshot(
                fromCanonical: target.url,
                maximumBytes: maximumBytes,
                path: target.relativePath,
                rejectHiddenDescendantsOf: protectedRoot,
                didReadBytes: didReadBytes
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

    /// Returns descriptor-bound metadata without reading file bytes or applying content limits.
    static func stableMetadata(
        _ target: ReadableFileTarget,
        vaultRoot: URL
    ) throws -> RegularFileMetadata {
        try target.revalidate()
        do {
            return try BoundedFileReader.withStableFileDescriptor(
                fromCanonical: target.url,
                maximumBytes: Int.max,
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

    /// Copies already captured bytes into private storage for URL-only decoders.
    static func temporarySnapshot(
        _ snapshot: FileSnapshot,
        target: ReadableFileTarget
    ) throws -> VaultTemporaryFileSnapshot {
        try Task.checkCancellation()
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
                contents: snapshot.data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return VaultTemporaryFileSnapshot(
                url: snapshotURL,
                byteCount: snapshot.data.count,
                directoryURL: directoryURL
            )
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }
}
