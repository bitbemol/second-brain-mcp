import Foundation

/// Validates every file a bulk directory rename can introduce into Git history.
enum DirectoryMoveSecurityPreflight {
    private static let maximumEntries = 100_000
    private static let maximumScannedTextBytes = 1_024 * 1_024 * 1_024

    static func validate(
        _ target: NotesDirectoryTarget
    ) throws {
        try target.revalidate()
        let errors = EnumerationErrors()
        guard let enumerator = FileManager.default.enumerator(
            at: target.url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [],
            errorHandler: { _, _ in
                errors.mark()
                return false
            }
        ) else {
            throw DirectoryMoveError.unsafeFilesystemOperation("enumerate subtree")
        }

        var entries = 0
        var scannedTextBytes = 0
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            entries += 1
            guard entries <= maximumEntries else {
                throw DirectoryMoveError.resourceLimit("more than \(maximumEntries) entries")
            }
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                throw PathValidationError.symbolicLinkNotAllowed(
                    relativePath(url, vaultPath: target.vaultPath)
                )
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw DirectoryMoveError.unsafeFilesystemOperation("inspect subtree entry")
            }

            let path = relativePath(url, vaultPath: target.vaultPath)
            let format = FileFormat.allCases.first { $0.accepts(path: path) }
            let maximumBytes = format?.maximumFileBytes
                ?? FileFormat.log.maximumFileBytes
            let metadata = try RegularFileInspector.inspect(url)
            guard metadata.byteCount <= maximumBytes else {
                throw FileResourcePolicy.Violation(
                    path: path,
                    bytes: metadata.byteCount,
                    limit: maximumBytes
                )
            }
            guard format?.isTextual == true || format == nil else { continue }

            scannedTextBytes += metadata.byteCount
            guard scannedTextBytes <= maximumScannedTextBytes else {
                throw DirectoryMoveError.resourceLimit("more than 1 GiB of text")
            }
            let data = try BoundedFileReader.read(
                from: url,
                maximumBytes: maximumBytes,
                path: path
            )
            if let format {
                try SensitiveContentPolicy.validate(data, format: format, path: path)
            } else if String(data: data, encoding: .utf8) != nil {
                // Unknown UTF-8 files receive the same conservative detector set
                // as generic logs; opaque binary files are never regex-scanned.
                try SensitiveContentPolicy.validate(data, format: .log, path: path)
            }
        }
        guard !errors.encountered else {
            throw DirectoryMoveError.unsafeFilesystemOperation("enumerate complete subtree")
        }
    }

    private static func relativePath(_ url: URL, vaultPath: String) -> String {
        let root = URL(fileURLWithPath: vaultPath).standardized.path
        let path = url.standardized.path
        guard path.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    private final class EnumerationErrors: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var encountered: Bool {
            lock.withLock { value }
        }

        func mark() {
            lock.withLock { value = true }
        }
    }
}
