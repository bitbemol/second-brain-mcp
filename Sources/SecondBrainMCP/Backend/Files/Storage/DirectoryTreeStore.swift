import Darwin
import Foundation

/// Descriptor-based atomic rename of a complete notes directory subtree.
struct DirectoryTreeStore: Sendable {
    struct Identity: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    enum State: Equatable, Sendable {
        case missing
        case directory(Identity)
        case other
    }

    private let notesRoot: URL

    init(vaultPath: String) {
        notesRoot = URL(fileURLWithPath: vaultPath)
            .standardized
            .resolvingSymlinksInPath()
            .appendingPathComponent(VaultArea.notes.rawValue, isDirectory: true)
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
        return .directory(Identity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        ))
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
        let destinationParent = try openDirectory(
            from: root,
            components: Array(destinationParts.dropLast()),
            createMissing: true,
            displayPath: destination.relativePath
        )
        defer { Darwin.close(destinationParent.descriptor) }

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
            let identity = Identity(
                device: UInt64(sourceMetadata.st_dev),
                inode: UInt64(sourceMetadata.st_ino)
            )
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
                  UInt64(moved.st_dev) == identity.device,
                  UInt64(moved.st_ino) == identity.inode else {
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
            for path in destinationParent.createdPaths.reversed() {
                _ = Darwin.rmdir(path)
            }
            throw error
        }
    }

    private struct OpenedDirectory {
        let descriptor: Int32
        let createdPaths: [String]
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
        var created: [String] = []
        var accumulated = notesRoot
        do {
            for component in components {
                try Task.checkCancellation()
                accumulated.appendPathComponent(component, isDirectory: true)
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
                    if made == 0 { created.append(accumulated.path) }
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
                Darwin.close(current)
                current = next
            }
            return OpenedDirectory(descriptor: current, createdPaths: created)
        } catch {
            Darwin.close(current)
            for path in created.reversed() { _ = Darwin.rmdir(path) }
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
}
