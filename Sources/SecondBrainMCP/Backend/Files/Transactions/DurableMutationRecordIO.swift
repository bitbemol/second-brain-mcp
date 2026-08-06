import Darwin
import Foundation

/// Crash-durable atomic I/O for small mutation transaction records.
///
/// The transaction store owns record schemas and validation. This type owns only
/// descriptor-safe replacement/removal and containing-directory synchronization.
enum DurableMutationRecordIO {
    /// Reads one bounded record if it currently exists.
    static func read(
        from url: URL,
        maximumBytes: Int,
        displayPath: String
    ) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try BoundedFileReader.read(
            from: url,
            maximumBytes: maximumBytes,
            path: displayPath
        )
    }

    /// Atomically replaces one record and fsyncs its containing directory.
    static func write(
        _ data: Data,
        destination: URL,
        temporaryPrefix: String
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            "\(temporaryPrefix).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw persistenceError(
                path: temporary.path,
                operation: "create temporary"
            )
        }

        var descriptorOpen = true
        var renamed = false
        defer {
            if descriptorOpen {
                _ = Darwin.close(descriptor)
            }
            if !renamed {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        try writeAll(data, descriptor: descriptor, path: temporary.path)
        try synchronize(descriptor: descriptor, path: temporary.path)
        let closeResult = Darwin.close(descriptor)
        descriptorOpen = false
        guard closeResult == 0 else {
            throw persistenceError(
                path: temporary.path,
                operation: "close temporary"
            )
        }
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw persistenceError(
                path: destination.path,
                operation: "replace"
            )
        }
        renamed = true

        // The rename is atomically visible; the directory sync makes its name
        // durable before persistence may cross the transaction point of no return.
        try synchronizeDirectory(directory)
    }

    /// Removes one record and fsyncs its containing directory.
    static func remove(_ url: URL, operation: String) throws {
        guard Darwin.unlink(url.path) == 0 else {
            if errno == ENOENT { return }
            throw persistenceError(path: url.path, operation: operation)
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32,
        path: String
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw MutationReceiptStore.ReceiptError.persistence(
                        path: path,
                        operation: "write",
                        code: written == 0 ? EIO : errno
                    )
                }
            }
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw persistenceError(
                path: directory.path,
                operation: "open directory"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        try synchronize(descriptor: descriptor, path: directory.path)
    }

    private static func synchronize(descriptor: Int32, path: String) throws {
        while Darwin.fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw persistenceError(path: path, operation: "synchronize")
            }
        }
    }

    private static func persistenceError(
        path: String,
        operation: String
    ) -> MutationReceiptStore.ReceiptError {
        .persistence(path: path, operation: operation, code: errno)
    }
}
