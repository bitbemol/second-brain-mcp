import Darwin
import Foundation

/// Descriptor-anchored private namespace under a trusted prepared app-data parent.
/// This is not a general caller-controlled absolute-path walker. Only a bounded
/// flat owned capture may be removed; source paths use BoundedFileReader instead.
final class SearchCaptureDirectory: @unchecked Sendable {
    private var descriptor: Int32
    private let mutex = NSLock()

    init(directory: URL) throws {
        let parent = Darwin.open(
            directory.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard parent >= 0 else { throw SearchCaptureStorageError() }
        defer { Darwin.close(parent) }
        try Self.requireOwnedDirectory(parent)
        let name = directory.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw SearchCaptureStorageError()
        }
        if Darwin.mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
            throw SearchCaptureStorageError()
        }
        let opened = Darwin.openat(parent, name, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard opened >= 0 else { throw SearchCaptureStorageError() }
        do {
            try Self.requireOwnedDirectory(opened)
            guard Darwin.fchmod(opened, 0o700) == 0 else { throw SearchCaptureStorageError() }
            descriptor = opened
        } catch {
            Darwin.close(opened)
            throw error
        }
    }

    func createCapture() throws -> Int32 {
        try mutex.withLock {
            guard descriptor >= 0, Darwin.mkdirat(descriptor, "active", 0o700) == 0 else {
                throw SearchCaptureStorageError()
            }
            let result = Darwin.openat(
                descriptor, "active", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
            )
            guard result >= 0 else { throw SearchCaptureStorageError() }
            do { try Self.requireOwnedDirectory(result) } catch {
                Darwin.close(result)
                throw error
            }
            return result
        }
    }

    /// No recursive removal, no cancellation checks, no following links, and a fixed scan ceiling.
    func removeAbandonedCapture() throws {
        try mutex.withLock {
            guard descriptor >= 0 else { throw SearchCaptureStorageError() }
            let active = Darwin.openat(
                descriptor, "active", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
            )
            if active < 0 {
                if errno == ENOENT { return }
                throw SearchCaptureStorageError()
            }
            defer { Darwin.close(active) }
            try Self.requireOwnedDirectory(active)
            var identity = stat()
            guard Darwin.fstat(active, &identity) == 0 else { throw SearchCaptureStorageError() }
            let duplicate = Darwin.dup(active)
            guard duplicate >= 0 else { throw SearchCaptureStorageError() }
            guard let stream = Darwin.fdopendir(duplicate) else {
                Darwin.close(duplicate)
                throw SearchCaptureStorageError()
            }
            defer { Darwin.closedir(stream) }
            var names: [String] = []
            var payload = 0
            while true {
                errno = 0
                guard let entry = Darwin.readdir(stream) else {
                    guard errno == 0 else { throw SearchCaptureStorageError() }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }
                guard names.count < 10_000, Self.isCaptureName(name) else {
                    throw SearchCaptureStorageError()
                }
                let metadata = try Self.regularMetadata(at: name, relativeTo: active)
                guard metadata.st_size >= 0,
                      metadata.st_size <= 256 * 1_024 * 1_024 - payload else {
                    throw SearchCaptureStorageError()
                }
                payload += Int(metadata.st_size)
                names.append(name)
            }
            for name in names {
                _ = try Self.regularMetadata(at: name, relativeTo: active)
                guard Darwin.unlinkat(active, name, 0) == 0 else { throw SearchCaptureStorageError() }
            }
            var current = stat()
            guard Darwin.fstatat(descriptor, "active", &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
                  Darwin.unlinkat(descriptor, "active", AT_REMOVEDIR) == 0 else {
                throw SearchCaptureStorageError()
            }
        }
    }

    func close() {
        mutex.withLock {
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        }
    }

    deinit { close() }

    static func requireOwnedDirectory(_ descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else { throw SearchCaptureStorageError() }
    }

    static func regularMetadata(at name: String, relativeTo directory: Int32) throws -> stat {
        var metadata = stat()
        guard Darwin.fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1 else {
            throw SearchCaptureStorageError()
        }
        return metadata
    }

    private static func isCaptureName(_ value: String) -> Bool {
        guard value.utf8.count == 16, value.hasSuffix(".capture") else { return false }
        let prefix = value.prefix(8)
        return prefix.utf8.allSatisfy { (48...57).contains($0) }
            && (Int(prefix).map { $0 < 10_000 } ?? false)
    }
}
