import Darwin
import Foundation

/// Opens and reads regular-file bytes without following raced symbolic links.
enum BoundedFileReader {
    /// Structural or stability failure observed on the opened descriptor.
    enum ReadError: Error, Sendable {
        case notFound
        case notARegularFile
        case hiddenComponent
        case changedDuringRead
    }

    /// Bytes and metadata captured from the same stable opened descriptor.
    struct Snapshot: Sendable {
        let data: Data
        let metadata: RegularFileMetadata
    }

    private struct Fingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modificationSeconds: time_t
        let modificationNanoseconds: Int64
        let changeSeconds: time_t
        let changeNanoseconds: Int64

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            modificationSeconds = value.st_mtimespec.tv_sec
            modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changeSeconds = value.st_ctimespec.tv_sec
            changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }
    }

    private static let chunkBytes = 64 * 1_024

    /// Reads a regular file through the caller's standardized absolute path.
    ///
    /// No path component is resolved before the protected descriptor walk, so
    /// a symbolic-link replacement cannot redirect the open. Vault reads use
    /// ``snapshot(fromCanonical:maximumBytes:path:)`` directly because their
    /// target URL has already crossed the containment boundary.
    static func read(
        from url: URL,
        maximumBytes: Int,
        path: String,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Data {
        return try snapshot(
            fromCanonical: url.standardized,
            maximumBytes: maximumBytes,
            path: path,
            cancellationCheck: cancellationCheck
        ).data
    }

    /// Opens every canonical path component with `O_NOFOLLOW`, validates the
    /// descriptor as a regular file, then reads at most one byte past the cap.
    ///
    /// A second descriptor stat rejects ordinary in-place changes during the
    /// read. Atomic pathname replacement is safe: the descriptor continues to
    /// identify the immutable version that was opened.
    static func snapshot(
        fromCanonical url: URL,
        maximumBytes: Int,
        path: String,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() },
        descriptorDidClose: ((Int32) -> Void)? = nil,
        rejectHiddenDescendantsOf protectedRoot: URL? = nil
    ) throws -> Snapshot {
        let captured = try withStableFileDescriptor(
            fromCanonical: url,
            maximumBytes: maximumBytes,
            path: path,
            cancellationCheck: cancellationCheck,
            descriptorDidClose: descriptorDidClose,
            rejectHiddenDescendantsOf: protectedRoot
        ) { descriptor, initialBytes in
            var data = Data()
            data.reserveCapacity(initialBytes)
            var buffer = [UInt8](repeating: 0, count: chunkBytes)
            while true {
                try cancellationCheck()
                let remaining = maximumBytes - data.count
                let requested = min(chunkBytes, max(remaining, 1))
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, requested)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= maximumBytes else {
                    throw FileResourcePolicy.Violation(
                        path: path,
                        bytes: data.count,
                        limit: maximumBytes
                    )
                }
            }
            return data
        }
        return Snapshot(data: captured.value, metadata: captured.metadata)
    }

    /// Runs a bounded streaming operation against one safely opened descriptor.
    ///
    /// The caller may consume the descriptor only inside `operation`. Metadata
    /// and the descriptor fingerprint are validated before and after it, making
    /// this suitable for copies that must not materialize the complete file.
    static func withStableFileDescriptor<Value>(
        fromCanonical url: URL,
        maximumBytes: Int,
        path: String,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() },
        descriptorDidClose: ((Int32) -> Void)? = nil,
        rejectHiddenDescendantsOf protectedRoot: URL? = nil,
        operation: (Int32, Int) throws -> Value
    ) throws -> (value: Value, metadata: RegularFileMetadata) {
        guard maximumBytes >= 0 else {
            throw FileResourcePolicy.Violation(
                path: path,
                bytes: 0,
                limit: maximumBytes
            )
        }
        try cancellationCheck()
        let descriptor = try openCanonical(
            url,
            cancellationCheck: cancellationCheck,
            descriptorDidClose: descriptorDidClose,
            rejectHiddenDescendantsOf: protectedRoot
        )
        defer {
            Darwin.close(descriptor)
            descriptorDidClose?(descriptor)
        }

        var initial = stat()
        guard Darwin.fstat(descriptor, &initial) == 0 else {
            throw posixError()
        }
        guard initial.st_mode & S_IFMT == S_IFREG else {
            throw ReadError.notARegularFile
        }
        let initialBytes = boundedInteger(initial.st_size)
        guard initialBytes <= maximumBytes else {
            throw FileResourcePolicy.Violation(
                path: path,
                bytes: initialBytes,
                limit: maximumBytes
            )
        }
        let initialFingerprint = Fingerprint(initial)
        let value = try operation(descriptor, initialBytes)

        try cancellationCheck()
        var final = stat()
        guard Darwin.fstat(descriptor, &final) == 0 else {
            throw posixError()
        }
        guard Fingerprint(final) == initialFingerprint else {
            throw ReadError.changedDuringRead
        }
        let seconds = TimeInterval(initial.st_mtimespec.tv_sec)
            + TimeInterval(initial.st_mtimespec.tv_nsec) / 1_000_000_000
        return (
            value,
            RegularFileMetadata(
                byteCount: initialBytes,
                modificationDate: Date(timeIntervalSince1970: seconds),
                deviceID: UInt64(initial.st_dev),
                inode: UInt64(initial.st_ino),
                modificationNanoseconds: Int64(initial.st_mtimespec.tv_nsec),
                changeSeconds: Int64(initial.st_ctimespec.tv_sec),
                changeNanoseconds: Int64(initial.st_ctimespec.tv_nsec)
            )
        )
    }

    private static func openCanonical(
        _ url: URL,
        cancellationCheck: () throws -> Void,
        descriptorDidClose: ((Int32) -> Void)?,
        rejectHiddenDescendantsOf protectedRoot: URL?
    ) throws -> Int32 {
        let path = url.standardized.path
        guard path.hasPrefix("/") else { throw ReadError.notARegularFile }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw ReadError.notARegularFile }
        let protectedComponentCount = protectedRoot.map {
            $0.standardized.resolvingSymlinksInPath().pathComponents.count - 1
        }

        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw posixError() }
        // Own the currently open component on every throwing path, including
        // cancellation between components. Ownership is transferred only when
        // the complete final descriptor is returned to `snapshot`.
        defer {
            if descriptor >= 0 {
                Darwin.close(descriptor)
                descriptorDidClose?(descriptor)
            }
        }

        for (index, component) in components.enumerated() {
            try cancellationCheck()
            let isFinal = index == components.count - 1
            let flags = isFinal
                ? O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                : O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
            var next = component.withCString {
                Darwin.openat(descriptor, $0, flags)
            }
            var observedErrno = errno
            if next < 0, index == 0, observedErrno == ENOTDIR {
                // macOS exposes protected root aliases such as /var ->
                // /private/var, while Foundation intentionally preserves the
                // /var spelling. Only the root-owned first component may be
                // followed; every caller-controlled descendant remains
                // O_NOFOLLOW.
                next = component.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_CLOEXEC | O_DIRECTORY
                    )
                }
                observedErrno = errno
            }
            Darwin.close(descriptor)
            descriptorDidClose?(descriptor)
            descriptor = -1
            guard next >= 0 else {
                switch observedErrno {
                case ENOENT: throw ReadError.notFound
                case ELOOP, ENOTDIR: throw ReadError.notARegularFile
                default:
                    errno = observedErrno
                    throw posixError()
                }
            }
            if let protectedComponentCount,
               index >= protectedComponentCount {
                var metadata = stat()
                if Darwin.fstat(next, &metadata) != 0 {
                    let code = errno
                    Darwin.close(next)
                    errno = code
                    throw posixError()
                }
                guard metadata.st_flags & UInt32(UF_HIDDEN) == 0 else {
                    Darwin.close(next)
                    throw ReadError.hiddenComponent
                }
            }
            descriptor = next
        }
        let result = descriptor
        descriptor = -1
        return result
    }

    private static func boundedInteger(_ value: off_t) -> Int {
        guard value > 0 else { return 0 }
        return value > off_t(Int.max) ? Int.max : Int(value)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
