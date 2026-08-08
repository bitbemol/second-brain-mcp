import Darwin
import Foundation

/// Descriptor-based atomic rename of a complete notes directory subtree.
struct DirectoryTreeStore: Sendable {
    struct Identity: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
    }

    enum State: Equatable, Sendable {
        case missing
        case directory(Identity)
        case other
    }

    private let notesRoot: URL
    private let beforeRename: (@Sendable () throws -> Void)?

    init(
        vaultPath: String,
        beforeRename: (@Sendable () throws -> Void)? = nil
    ) {
        notesRoot = URL(fileURLWithPath: vaultPath)
            .standardized
            .resolvingSymlinksInPath()
            .appendingPathComponent(VaultArea.notes.rawValue, isDirectory: true)
        self.beforeRename = beforeRename
    }

    func state(of target: NotesDirectoryTarget) throws -> State {
        var metadata = stat()
        guard Darwin.lstat(target.url.path, &metadata) == 0 else {
            if errno == ENOENT { return .missing }
            throw DirectoryMoveError.unsafeFilesystemOperation("inspect \(target.relativePath)")
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return .other }
        guard metadata.st_flags & UInt32(UF_HIDDEN) == 0 else {
            throw DirectoryMoveError.hiddenDirectory(target.relativePath)
        }
        return .directory(identity(metadata))
    }

    /// Atomically renames without following any notes-descendant symbolic link.
    func move(
        source: NotesDirectoryTarget,
        destination: NotesDirectoryTarget,
        expectedIdentity: Identity
    ) throws -> Identity {
        try source.revalidate()
        try destination.revalidate()
        let sourceParts = source.descendants
        let destinationParts = destination.descendants
        guard let sourceName = sourceParts.last,
              let destinationName = destinationParts.last else {
            throw DirectoryMoveError.invalidDirectoryPath(source.relativePath)
        }

        let root = Darwin.open(
            notesRoot.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard root >= 0 else {
            throw DirectoryMoveError.unsafeFilesystemOperation("open notes root")
        }
        defer { Darwin.close(root) }

        let sourceParent = try openDirectory(
            from: root,
            components: Array(sourceParts.dropLast()),
            createMissing: false,
            displayPath: source.relativePath
        )
        defer { Darwin.close(sourceParent.descriptor) }
        defer { release(sourceParent.createdDirectories) }
        let destinationParent = try openDirectory(
            from: root,
            components: Array(destinationParts.dropLast()),
            createMissing: true,
            displayPath: destination.relativePath
        )
        defer { Darwin.close(destinationParent.descriptor) }
        defer { release(destinationParent.createdDirectories) }

        do {
            let sourceDescriptor = try openChildDirectory(
                parent: sourceParent.descriptor,
                name: sourceName,
                displayPath: source.relativePath
            )
            defer { Darwin.close(sourceDescriptor) }
            var sourceMetadata = stat()
            guard Darwin.fstat(sourceDescriptor, &sourceMetadata) == 0 else {
                throw DirectoryMoveError.unsafeFilesystemOperation("inspect source")
            }
            guard sourceMetadata.st_flags & UInt32(UF_HIDDEN) == 0 else {
                throw DirectoryMoveError.hiddenDirectory(source.relativePath)
            }
            let identity = identity(sourceMetadata)
            guard identity == expectedIdentity else {
                throw DirectoryMoveError.unsafeFilesystemOperation(
                    "verify unchanged source identity"
                )
            }

            var existing = stat()
            if destinationName.withCString({
                Darwin.fstatat(destinationParent.descriptor, $0, &existing, AT_SYMLINK_NOFOLLOW)
            }) == 0 {
                throw DirectoryMoveError.destinationExists(destination.relativePath)
            }
            guard errno == ENOENT else {
                throw DirectoryMoveError.unsafeFilesystemOperation("inspect destination")
            }

            try beforeRename?()
            let result = sourceName.withCString { sourcePointer in
                destinationName.withCString { destinationPointer in
                    Darwin.renameatx_np(
                        sourceParent.descriptor,
                        sourcePointer,
                        destinationParent.descriptor,
                        destinationPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard result == 0 else {
                if errno == EEXIST { throw DirectoryMoveError.destinationExists(destination.relativePath) }
                if errno == ENOENT { throw DirectoryMoveError.sourceNotFound(source.relativePath) }
                throw DirectoryMoveError.unsafeFilesystemOperation("rename subtree")
            }

            var moved = stat()
            guard destinationName.withCString({
                Darwin.fstatat(destinationParent.descriptor, $0, &moved, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                  moved.st_mode & S_IFMT == S_IFDIR,
                  self.identity(moved) == identity else {
                throw DirectoryMoveError.unsafeFilesystemOperation("verify destination")
            }
            guard Darwin.fsync(sourceParent.descriptor) == 0 else {
                throw DirectoryMoveError.unsafeFilesystemOperation("synchronize source parent")
            }
            if destinationParent.descriptor != sourceParent.descriptor,
               Darwin.fsync(destinationParent.descriptor) != 0 {
                throw DirectoryMoveError.unsafeFilesystemOperation("synchronize destination parent")
            }
            return identity
        } catch {
            cleanup(destinationParent.createdDirectories)
            throw error
        }
    }

    private struct CreatedDirectory {
        let parentDescriptor: Int32
        let name: String
        let identity: Identity
    }

    private struct OpenedDirectory {
        let descriptor: Int32
        let createdDirectories: [CreatedDirectory]
    }

    private func openDirectory(
        from root: Int32,
        components: [String],
        createMissing: Bool,
        displayPath: String
    ) throws -> OpenedDirectory {
        var current = Darwin.dup(root)
        guard current >= 0 else {
            throw DirectoryMoveError.unsafeFilesystemOperation("duplicate notes descriptor")
        }
        var created: [CreatedDirectory] = []
        do {
            for component in components {
                try Task.checkCancellation()
                var wasCreated = false
                var next = component.withCString {
                    Darwin.openat(
                        current,
                        $0,
                        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                    )
                }
                if next < 0, errno == ENOENT, createMissing {
                    let made = component.withCString { Darwin.mkdirat(current, $0, 0o755) }
                    guard made == 0 || errno == EEXIST else {
                        throw DirectoryMoveError.unsafeFilesystemOperation("create destination parent")
                    }
                    wasCreated = made == 0
                    next = component.withCString {
                        Darwin.openat(
                            current,
                            $0,
                            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                        )
                    }
                }
                guard next >= 0 else {
                    if errno == ENOENT {
                        throw DirectoryMoveError.sourceNotFound(displayPath)
                    }
                    throw DirectoryMoveError.unsafeFilesystemOperation("open directory component")
                }
                var metadata = stat()
                guard Darwin.fstat(next, &metadata) == 0,
                      metadata.st_mode & S_IFMT == S_IFDIR else {
                    Darwin.close(next)
                    throw DirectoryMoveError.sourceNotDirectory(displayPath)
                }
                guard metadata.st_flags & UInt32(UF_HIDDEN) == 0 else {
                    Darwin.close(next)
                    throw DirectoryMoveError.hiddenDirectory(displayPath)
                }
                if wasCreated {
                    let cleanupParent = Darwin.dup(current)
                    guard cleanupParent >= 0 else {
                        Darwin.close(next)
                        _ = component.withCString {
                            Darwin.unlinkat(current, $0, AT_REMOVEDIR)
                        }
                        throw DirectoryMoveError.unsafeFilesystemOperation(
                            "retain destination parent descriptor"
                        )
                    }
                    created.append(CreatedDirectory(
                        parentDescriptor: cleanupParent,
                        name: component,
                        identity: identity(metadata)
                    ))
                }
                Darwin.close(current)
                current = next
            }
            return OpenedDirectory(
                descriptor: current,
                createdDirectories: created
            )
        } catch {
            Darwin.close(current)
            cleanup(created)
            release(created)
            throw error
        }
    }

    private func openChildDirectory(
        parent: Int32,
        name: String,
        displayPath: String
    ) throws -> Int32 {
        let descriptor = name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw DirectoryMoveError.sourceNotFound(displayPath) }
            if errno == ENOTDIR { throw DirectoryMoveError.sourceNotDirectory(displayPath) }
            throw DirectoryMoveError.unsafeFilesystemOperation("open source directory")
        }
        return descriptor
    }

    private func cleanup(_ created: [CreatedDirectory]) {
        for directory in created.reversed() {
            var current = stat()
            let inspected = directory.name.withCString {
                Darwin.fstatat(
                    directory.parentDescriptor,
                    $0,
                    &current,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard inspected == 0,
                  current.st_mode & S_IFMT == S_IFDIR,
                  identity(current) == directory.identity else { continue }
            _ = directory.name.withCString {
                Darwin.unlinkat(directory.parentDescriptor, $0, AT_REMOVEDIR)
            }
        }
    }

    private func release(_ created: [CreatedDirectory]) {
        for directory in created {
            Darwin.close(directory.parentDescriptor)
        }
    }

    private func identity(_ metadata: stat) -> Identity {
        Identity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            birthSeconds: Int64(metadata.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec)
        )
    }
}
