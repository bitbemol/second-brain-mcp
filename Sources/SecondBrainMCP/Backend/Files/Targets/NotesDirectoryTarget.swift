import Foundation

/// Canonical directory path that can represent only a proper subtree of `notes/`.
struct NotesDirectoryTarget: Equatable, Sendable {
    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "pages", "pkg", "playground",
        "plugin", "rtfd", "xcodeproj", "xcworkspace",
    ]
    let url: URL
    let relativePath: String
    let vaultPath: String

    /// Canonicalizes and validates a friendly vault-relative spelling without
    /// consulting the filesystem.
    static func canonicalize(path: String) throws -> String {
        guard !path.isEmpty else { throw PathValidationError.emptyPath }
        guard path.utf8.count <= DirectoryMoveRequestLimits.maximumPathBytes else {
            throw DirectoryMoveError.pathTooLong
        }
        guard !path.hasPrefix("/"), !path.contains("\0") else {
            throw PathValidationError.absolutePathNotAllowed(path)
        }
        guard !PathTraversalDetector.containsTraversal(in: path) else {
            throw PathValidationError.pathContainsTraversal(path)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= 2, components.first == VaultArea.notes.rawValue else {
            throw FileRoutingError.areaNotWritable(path)
        }
        guard components.allSatisfy({ component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && !component.hasPrefix(".")
                && component.utf8.count <= 255
        }) else {
            throw DirectoryMoveError.invalidDirectoryPath(path)
        }
        guard components.dropFirst().allSatisfy({ component in
            !packageExtensions.contains(
                (component as NSString).pathExtension.lowercased()
            )
        }) else {
            throw DirectoryMoveError.invalidDirectoryPath(path)
        }
        let canonicalPath = components.joined(separator: "/")
        guard canonicalPath.utf8.count <= DirectoryMoveRequestLimits.maximumPathBytes else {
            throw DirectoryMoveError.pathTooLong
        }
        return canonicalPath
    }

    /// Resolves a canonical spelling and rejects symbolic-link paths. The final
    /// directory may be absent for destinations.
    static func resolve(path: String, vaultPath: String) throws -> NotesDirectoryTarget {
        let canonicalPath = try canonicalize(path: path)
        let resolved = try PathValidator.resolve(
            relativePath: canonicalPath,
            root: vaultPath
        )
        guard !PathValidator.containsSymbolicLinkComponent(
            relativePath: canonicalPath,
            root: vaultPath
        ) else {
            throw PathValidationError.symbolicLinkNotAllowed(canonicalPath)
        }
        let canonicalVault = URL(fileURLWithPath: vaultPath)
            .standardized
            .resolvingSymlinksInPath()
        let expected = canonicalVault.appendingPathComponent(canonicalPath).standardized
        guard resolved == expected.path else {
            throw PathValidationError.symbolicLinkNotAllowed(canonicalPath)
        }
        return NotesDirectoryTarget(
            url: expected,
            relativePath: canonicalPath,
            vaultPath: canonicalVault.path
        )
    }

    func revalidate() throws {
        let current = try Self.resolve(path: relativePath, vaultPath: vaultPath)
        guard current.url == url else {
            throw PathValidationError.pathChangedSinceValidation(relativePath)
        }
    }

    var descendants: [String] {
        Array(relativePath.split(separator: "/").dropFirst()).map(String.init)
    }
}

/// Safe, caller-facing directory-move failures.
enum DirectoryMoveError: Error, CustomStringConvertible, Sendable {
    case pathTooLong
    case invalidDirectoryPath(String)
    case sourceNotFound(String)
    case sourceNotDirectory(String)
    case destinationExists(String)
    case sourceAndDestinationAreSame
    case destinationInsideSource
    case hiddenDirectory(String)
    case resourceLimit(String)
    case unsafeFilesystemOperation(String)

    var description: String {
        switch self {
        case .pathTooLong:
            "Directory path exceeds the UTF-8 byte limit"
        case .invalidDirectoryPath(let path):
            "Invalid notes directory path: \(path)"
        case .sourceNotFound(let path):
            "Source directory does not exist: \(path)"
        case .sourceNotDirectory(let path):
            "Source is not a regular directory: \(path)"
        case .destinationExists(let path):
            "Destination already exists: \(path)"
        case .sourceAndDestinationAreSame:
            "Source and destination resolve to the same directory"
        case .destinationInsideSource:
            "A directory cannot be moved into its own subtree"
        case .hiddenDirectory(let path):
            "Hidden directories cannot be moved through the managed notes boundary: \(path)"
        case .resourceLimit(let detail):
            "Directory move exceeds its bounded resource policy: \(detail)"
        case .unsafeFilesystemOperation(let operation):
            "Directory move could not safely \(operation)"
        }
    }
}
