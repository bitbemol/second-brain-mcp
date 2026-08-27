import Darwin
import Foundation

/// Filesystem primitives for CRUD after policy and exact-byte revision checks.
/// Directory descriptors remain pinned through commit; raced symlinks cannot
/// redirect persistence. An unrelated OS rename may still move a pinned directory:
/// this is not a universal cross-application pathname compare-and-swap.
struct VaultDescriptorPersistence: Sendable {
    private let vaultRoot: URL
    private let beforeCommit: (@Sendable () throws -> Void)?

    init(vaultPath: String, beforeCommit: (@Sendable () throws -> Void)? = nil) {
        vaultRoot = URL(fileURLWithPath: vaultPath).standardized.resolvingSymlinksInPath()
        self.beforeCommit = beforeCommit
    }

    func write(
        _ data: Data,
        to target: WritableFileTarget,
        replacing expected: RegularFileMetadata? = nil
    ) throws {
        try target.revalidate()
        try requireOwnedTarget(target)
        try withParent(of: target, createMissing: expected == nil) { parent in
            let name = target.url.lastPathComponent
            let source: Int32
            if let expected {
                source = try openSource(parent: parent, name: name, expected: expected, path: target.relativePath)
            } else {
                try requireAbsent(parent: parent, name: name, path: target.relativePath)
                source = -1
            }
            defer { if source >= 0 { Darwin.close(source) } }

            let temporary = ".secondbrain-\(UUID().uuidString).tmp"
            let descriptor = temporary.withCString {
                Darwin.openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o666)
            }
            guard descriptor >= 0 else { throw posixError() }
            defer {
                removeOwnedTemporary(parent: parent, name: temporary, descriptor: descriptor)
                Darwin.close(descriptor)
            }
            if source >= 0 {
                var attributes = stat()
                guard Darwin.fstat(source, &attributes) == 0,
                      Darwin.fchmod(descriptor, attributes.st_mode & 0o777) == 0 else {
                    throw posixError()
                }
            }
            try writeAll(data, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
            var prepared = stat()
            guard Darwin.fstat(descriptor, &prepared) == 0 else { throw posixError() }
            try beforeCommit?()
            try verifyTemporary(parent: parent, name: temporary, descriptor: descriptor, prepared: prepared)
            if let expected {
                try verifySource(
                    parent: parent, name: name, descriptor: source,
                    expected: expected, path: target.relativePath
                )
            }
            let result = temporary.withCString { temporaryName in
                name.withCString {
                    Darwin.renameatx_np(parent, temporaryName, parent, $0, expected == nil ? UInt32(RENAME_EXCL) : 0)
                }
            }
            guard result == 0 else {
                if errno == EEXIST { throw VaultCRUDStore.StoreError.alreadyExists(target.relativePath) }
                throw posixError()
            }
            guard Darwin.fsync(parent) == 0 else { throw posixError() }
        }
    }

    func moveToTrash(
        _ target: WritableFileTarget,
        expected: RegularFileMetadata,
        name: String
    ) throws {
        try target.revalidate()
        try requireOwnedTarget(target)
        try withVault { vault in
            try withDescendants(
                of: vault, components: Array(target.relativePath.split(separator: "/").dropLast()).map(String.init),
                createMissing: false
            ) { parent in
                let sourceName = target.url.lastPathComponent
                let source = try openSource(
                    parent: parent, name: sourceName, expected: expected, path: target.relativePath
                )
                defer { Darwin.close(source) }
                let trash = try openTrash(in: vault)
                defer { Darwin.close(trash) }
                try beforeCommit?()
                try verifySource(
                    parent: parent, name: sourceName, descriptor: source,
                    expected: expected, path: target.relativePath
                )
                let result = sourceName.withCString { sourcePointer in
                    name.withCString {
                        Darwin.renameatx_np(parent, sourcePointer, trash, $0, UInt32(RENAME_EXCL))
                    }
                }
                guard result == 0 else { throw posixError() }
                guard Darwin.fsync(parent) == 0, Darwin.fsync(trash) == 0,
                      Darwin.fsync(vault) == 0 else { throw posixError() }
            }
        }
    }

    private func requireOwnedTarget(_ target: WritableFileTarget) throws {
        guard CanonicalPathContainment.contains(
            path: target.url.path, within: vaultRoot.appendingPathComponent("notes").path
        ) else {
            throw FileRoutingError.areaNotWritable(target.relativePath)
        }
    }

    private func requireAbsent(parent: Int32, name: String, path: String) throws {
        var existing = stat()
        let result = name.withCString { Darwin.fstatat(parent, $0, &existing, AT_SYMLINK_NOFOLLOW) }
        if result == 0 { throw VaultCRUDStore.StoreError.alreadyExists(path) }
        guard errno == ENOENT else { throw posixError() }
    }

    private func openSource(
        parent: Int32, name: String, expected: RegularFileMetadata, path: String
    ) throws -> Int32 {
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if [ENOENT, ELOOP, ENOTDIR].contains(errno) {
                throw VaultCRUDStore.StoreError.changedSinceRead(path)
            }
            throw posixError()
        }
        do {
            try verifySource(parent: parent, name: name, descriptor: descriptor, expected: expected, path: path)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Metadata binds already-read, revision-checked bytes to the opened source.
    /// It is never used instead of hashing the mutation's current source bytes.
    private func verifySource(
        parent: Int32, name: String, descriptor: Int32,
        expected: RegularFileMetadata, path: String
    ) throws {
        var opened = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0 else { throw posixError() }
        let inspected = name.withCString { Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW) }
        guard inspected == 0 else {
            if errno == ENOENT { throw VaultCRUDStore.StoreError.changedSinceRead(path) }
            throw posixError()
        }
        guard matches(opened, expected), matches(named, expected) else {
            throw VaultCRUDStore.StoreError.changedSinceRead(path)
        }
    }

    private func matches(_ value: stat, _ expected: RegularFileMetadata) -> Bool {
        guard value.st_mode & S_IFMT == S_IFREG,
              let device = expected.deviceID, let inode = expected.inode,
              let changedSeconds = expected.changeSeconds,
              let changedNanoseconds = expected.changeNanoseconds else { return false }
        return UInt64(value.st_dev) == device && UInt64(value.st_ino) == inode
            && value.st_size == expected.byteCount
            && Int64(value.st_ctimespec.tv_sec) == changedSeconds
            && Int64(value.st_ctimespec.tv_nsec) == changedNanoseconds
    }

    private func openTrash(in vault: Int32) throws -> Int32 {
        var descriptor = Darwin.openat(vault, ".trash", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        if descriptor < 0, errno == ENOENT {
            guard Darwin.mkdirat(vault, ".trash", 0o755) == 0 || errno == EEXIST else {
                throw posixError()
            }
            descriptor = Darwin.openat(vault, ".trash", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw VaultCRUDStore.StoreError.unsafeTrashDirectory(".trash")
        }
        return descriptor
    }

    private func withParent<Value>(
        of target: WritableFileTarget, createMissing: Bool, operation: (Int32) throws -> Value
    ) throws -> Value {
        try withVault { vault in
            try withDescendants(
                of: vault, components: Array(target.relativePath.split(separator: "/").dropLast()).map(String.init),
                createMissing: createMissing, operation: operation
            )
        }
    }

    /// Every operation anchors the same vault descriptor before opening descendants.
    private func withVault<Value>(operation: (Int32) throws -> Value) throws -> Value {
        let root = Darwin.open("/", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw posixError() }
        defer { Darwin.close(root) }
        return try withDescendants(
            of: root, components: vaultRoot.path.split(separator: "/").map(String.init),
            createMissing: false, allowSystemRootAlias: true, operation: operation
        )
    }

    private func withDescendants<Value>(
        of root: Int32, components: [String], createMissing: Bool,
        allowSystemRootAlias: Bool = false, operation: (Int32) throws -> Value
    ) throws -> Value {
        var current = Darwin.dup(root)
        guard current >= 0 else { throw posixError() }
        defer { Darwin.close(current) }
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            var next = component.withCString {
                Darwin.openat(current, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
            }
            if next < 0, allowSystemRootAlias, index == 0, errno == ENOTDIR {
                // Same root-owned macOS /var and /tmp alias exception as the reader.
                next = component.withCString {
                    Darwin.openat(current, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
                }
            }
            if next < 0, errno == ENOENT, createMissing {
                guard component.withCString({ Darwin.mkdirat(current, $0, 0o755) }) == 0
                        || errno == EEXIST else { throw posixError() }
                next = component.withCString {
                    Darwin.openat(current, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
                }
            }
            guard next >= 0 else { throw posixError() }
            Darwin.close(current)
            current = next
        }
        return try operation(current)
    }

    private func verifyTemporary(
        parent: Int32, name: String, descriptor: Int32, prepared: stat
    ) throws {
        var opened = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              name.withCString({ Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw posixError()
        }
        for observed in [opened, named] {
            guard observed.st_mode & S_IFMT == S_IFREG,
                  observed.st_dev == prepared.st_dev, observed.st_ino == prepared.st_ino,
                  observed.st_size == prepared.st_size,
                  observed.st_ctimespec.tv_sec == prepared.st_ctimespec.tv_sec,
                  observed.st_ctimespec.tv_nsec == prepared.st_ctimespec.tv_nsec else {
                throw POSIXError(.EIO)
            }
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(
                    descriptor, bytes.baseAddress!.advanced(by: offset),
                    min(bytes.count - offset, 64 * 1024)
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }

    private func removeOwnedTemporary(parent: Int32, name: String, descriptor: Int32) {
        var opened = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              name.withCString({ Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { return }
        _ = name.withCString { Darwin.unlinkat(parent, $0, 0) }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
