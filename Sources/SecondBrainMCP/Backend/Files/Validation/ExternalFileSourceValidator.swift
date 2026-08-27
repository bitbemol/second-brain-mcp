import Darwin
import Foundation

/// A canonical external regular file approved for media import.
///
/// Construction is restricted to ``ExternalFileSourceValidator`` so image and
/// video handlers cannot accidentally consume an unchecked caller path.
struct ExternalFileSource: Sendable {
    /// Canonical file URL after resolving symbolic links.
    let url: URL
    /// Size of the resolved regular file in bytes.
    let byteCount: Int

    fileprivate init(url: URL, byteCount: Int) {
        self.url = url
        self.byteCount = byteCount
    }
}

/// Private immutable copy consumed by a complete external media import.
struct ExternalFileSnapshot: Sendable {
    /// Private file URL with the source extension preserved for media frameworks.
    let url: URL
    /// Bytes copied through the bounded opened descriptor.
    let byteCount: Int
    private let directoryURL: URL

    fileprivate init(url: URL, byteCount: Int, directoryURL: URL) {
        self.url = url
        self.byteCount = byteCount
        self.directoryURL = directoryURL
    }

    /// Removes the process-owned snapshot directory after conversion finishes.
    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

/// Resolves and validates arbitrary filesystem paths used by media imports.
///
/// This is the single external-source trust boundary. It resolves symbolic
/// links before checking file kind, byte size, and containment, ensuring every
/// media importer applies the same security policy to the real source file.
struct ExternalFileSourceValidator: Sendable {
    /// Failures raised before a media decoder may inspect an external source.
    enum ValidationError: Error, CustomStringConvertible, CallerSafeError, Sendable {
        /// No filesystem entry exists at the canonical source path.
        case sourceNotFound(String)
        /// The resolved source is not a regular file.
        case sourceNotAFile(String)
        /// The resolved source sits inside the managed vault.
        case sourceInsideVault(String)
        /// The resolved regular file exceeds the caller's byte limit.
        case sourceTooLarge(bytes: Int, limit: Int)

        /// Corrective policy only; never expose a caller or canonical filesystem path.
        var callerSafeDescription: String {
            switch self {
            case .sourceNotFound:
                "Source file not found; provide an existing external file path outside the vault."
            case .sourceNotAFile:
                "Source must be a readable regular file outside the vault; directories are not supported."
            case .sourceInsideVault:
                "Source must be outside the vault; choose an external file path."
            case .sourceTooLarge(let bytes, let limit):
                "Source file is too large: \(bytes) bytes (limit \(limit)); choose a smaller file."
            }
        }

        /// Human-readable external-source validation failure.
        var description: String {
            switch self {
            case .sourceNotFound(let path):
                "Source file not found: \(path)"
            case .sourceNotAFile(let path):
                "Source is not a regular file: \(path)"
            case .sourceInsideVault(let path):
                "Source is inside the managed vault: \(path)"
            case .sourceTooLarge(let bytes, let limit):
                "Source file is too large: \(bytes) bytes (limit \(limit))"
            }
        }
    }

    private let canonicalVaultPath: String

    /// Creates the external-source boundary for one managed vault.
    ///
    /// - Parameter vaultPath: Absolute vault root excluded from imports.
    init(vaultPath: String) {
        self.canonicalVaultPath = URL(fileURLWithPath: vaultPath)
            .resolvingSymlinksInPath()
            .path
    }

    /// Canonicalizes and validates an external source before media inspection.
    ///
    /// - Parameters:
    ///   - path: Caller-controlled filesystem path.
    ///   - maximumBytes: Maximum size of the resolved regular file.
    /// - Returns: A canonical source safe to pass to a media decoder.
    /// - Throws: ``ValidationError`` or a filesystem metadata error.
    func validate(path: String, maximumBytes: Int) throws -> ExternalFileSource {
        let canonicalURL = URL(
            fileURLWithPath: path.trimmingCharacters(in: .whitespaces)
        ).resolvingSymlinksInPath()
        let canonicalPath = canonicalURL.path
        let metadata: RegularFileMetadata
        do {
            metadata = try RegularFileInspector.inspect(canonicalURL)
        } catch RegularFileInspector.InspectionError.notFound {
            throw ValidationError.sourceNotFound(path)
        } catch RegularFileInspector.InspectionError.notARegularFile {
            throw ValidationError.sourceNotAFile(path)
        }

        let byteCount = metadata.byteCount
        guard byteCount <= maximumBytes else {
            throw ValidationError.sourceTooLarge(bytes: byteCount, limit: maximumBytes)
        }
        guard !CanonicalPathContainment.contains(
            path: canonicalPath,
            within: canonicalVaultPath
        ) else {
            throw ValidationError.sourceInsideVault(path)
        }

        return ExternalFileSource(url: canonicalURL, byteCount: byteCount)
    }

    /// Copies a validated source through one opened descriptor into private storage.
    ///
    /// Descriptor metadata and streamed byte counts are checked again after path
    /// validation. Media frameworks then reopen only the immutable private copy,
    /// preventing later source replacement from changing inspected or decoded data.
    func snapshot(
        path: String,
        maximumBytes: Int,
        sourceDidValidate: (() throws -> Void)? = nil
    ) throws -> ExternalFileSnapshot {
        let source = try validate(path: path, maximumBytes: maximumBytes)
        try sourceDidValidate?()

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainMCP-source-\(UUID().uuidString)")
        let sourceExtension = source.url.pathExtension
        let filename = sourceExtension.isEmpty ? "snapshot" : "snapshot.\(sourceExtension)"
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

            let copied: (value: Int, metadata: RegularFileMetadata)
            do {
                copied = try BoundedFileReader.withStableFileDescriptor(
                    fromCanonical: source.url,
                    maximumBytes: maximumBytes,
                    path: path
                ) { descriptor, _ in
                    var copiedBytes = 0
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
                            throw POSIXError(
                                POSIXErrorCode(rawValue: errno) ?? .EIO
                            )
                        }
                        copiedBytes += count
                        guard copiedBytes <= maximumBytes else {
                            throw ValidationError.sourceTooLarge(
                                bytes: copiedBytes,
                                limit: maximumBytes
                            )
                        }
                        try output.write(contentsOf: Data(buffer.prefix(count)))
                    }
                    return copiedBytes
                }
            } catch let violation as FileResourcePolicy.Violation {
                throw ValidationError.sourceTooLarge(
                    bytes: violation.bytes,
                    limit: violation.limit
                )
            } catch is BoundedFileReader.ReadError {
                throw ValidationError.sourceNotAFile(path)
            }
            guard copied.value == copied.metadata.byteCount else {
                throw ValidationError.sourceNotAFile(path)
            }
            return ExternalFileSnapshot(
                url: snapshotURL,
                byteCount: copied.value,
                directoryURL: directoryURL
            )
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }
}
