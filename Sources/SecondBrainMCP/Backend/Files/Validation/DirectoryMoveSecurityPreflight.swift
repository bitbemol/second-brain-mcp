import CryptoKit
import Darwin
import Foundation

/// Validates every file a bulk directory rename can introduce into Git history.
enum DirectoryMoveSecurityPreflight {
    private static let defaultMaximumEntries = 100_000
    private static let defaultMaximumSubtreeBytes = 1_024 * 1_024 * 1_024
    private static let defaultMaximumManifestPathBytes = 16 * 1_024 * 1_024

    struct Manifest: Equatable, Sendable {
        struct Entry: Equatable, Sendable {
            let byteCount: Int
            let sha256: String
            let gitSHA1: String
            let gitSHA256: String
            let gitMode: String
        }

        struct Summary: Codable, Equatable, Sendable {
            let digest: String
            let entryCount: Int
            let totalBytes: Int
        }

        let rootPath: String
        let entries: [String: Entry]
        let summary: Summary
        let aggregatePathBytes: Int

        func rebased(to destinationPath: String) throws -> Manifest {
            var rebased: [String: Entry] = [:]
            var pathBytes = 0
            for (path, entry) in entries {
                guard path.hasPrefix(rootPath + "/") else {
                    throw DirectoryMoveError.unsafeFilesystemOperation(
                        "rebase subtree manifest"
                    )
                }
                let suffix = path.dropFirst(rootPath.count)
                let destination = destinationPath + suffix
                let (nextBytes, overflow) = pathBytes.addingReportingOverflow(
                    destination.utf8.count
                )
                guard !overflow,
                      nextBytes <= Self.maximumAggregatePathBytes else {
                    throw DirectoryMoveError.resourceLimit(
                        "more than \(Self.maximumAggregatePathBytes) manifest path bytes"
                    )
                }
                pathBytes = nextBytes
                rebased[destination] = entry
            }
            return Manifest(
                rootPath: destinationPath,
                entries: rebased,
                summary: summary,
                aggregatePathBytes: pathBytes
            )
        }

        private static let maximumAggregatePathBytes =
            DirectoryMoveSecurityPreflight.defaultMaximumManifestPathBytes
    }

    static func validate(
        _ target: NotesDirectoryTarget,
        maximumEntries: Int = defaultMaximumEntries,
        maximumSubtreeBytes: Int = defaultMaximumSubtreeBytes,
        maximumManifestPathBytes: Int = defaultMaximumManifestPathBytes
    ) throws -> Manifest {
        try target.revalidate()
        let errors = EnumerationErrors()
        guard let enumerator = FileManager.default.enumerator(
            at: target.url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isHiddenKey,
                .isPackageKey,
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
        var subtreeBytes = 0
        var manifestPathBytes = 0
        var manifest: [String: Manifest.Entry] = [:]
        var summaryRecords: [SummaryRecord] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            entries += 1
            guard entries <= maximumEntries else {
                throw DirectoryMoveError.resourceLimit("more than \(maximumEntries) entries")
            }
            let path = relativePath(
                url,
                target: target,
                depth: enumerator.level
            )
            let (nextPathBytes, pathOverflow) = manifestPathBytes
                .addingReportingOverflow(path.utf8.count)
            guard !pathOverflow,
                  nextPathBytes <= maximumManifestPathBytes else {
                throw DirectoryMoveError.resourceLimit(
                    "more than \(maximumManifestPathBytes) manifest path bytes"
                )
            }
            manifestPathBytes = nextPathBytes
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isHiddenKey,
                .isPackageKey,
            ])
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                throw PathValidationError.symbolicLinkNotAllowed(
                    path
                )
            }
            let format = values.isRegularFile == true
                ? FileFormat.allCases.first { $0.accepts(path: path) }
                : nil
            // A supported dot-named leaf (for example .gitkeep.md) is ordinary
            // file content. It still passes descriptor, size and credential checks.
            // Hidden directories and unregistered control files remain excluded.
            let supportedDotFile = values.isRegularFile == true
                && url.lastPathComponent.hasPrefix(".") && format != nil
            if (values.isHidden == true || url.lastPathComponent.hasPrefix("."))
                && !supportedDotFile {
                if values.isDirectory == true { enumerator.skipDescendants() }
                throw DirectoryMoveError.hiddenDirectory(path)
            }
            if values.isPackage == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                throw DirectoryMoveError.invalidDirectoryPath(path)
            }
            if values.isDirectory == true {
                summaryRecords.append(SummaryRecord(
                    path: path,
                    gitMode: "040000",
                    byteCount: 0,
                    sha256: ""
                ))
                continue
            }
            guard values.isRegularFile == true else {
                throw DirectoryMoveError.unsafeFilesystemOperation("inspect subtree entry")
            }

            let maximumBytes = format?.maximumFileBytes
                ?? FileFormat.log.maximumFileBytes
            let snapshot = try stableSnapshot(
                url: url,
                path: path,
                format: format,
                maximumBytes: maximumBytes,
                protectedRoot: target.url
            )
            let (nextBytes, overflow) = subtreeBytes.addingReportingOverflow(
                snapshot.byteCount
            )
            guard !overflow, nextBytes <= maximumSubtreeBytes else {
                throw DirectoryMoveError.resourceLimit(
                    "more than \(maximumSubtreeBytes) bytes of files"
                )
            }
            subtreeBytes = nextBytes
            let entry = Manifest.Entry(
                byteCount: snapshot.byteCount,
                sha256: snapshot.sha256,
                gitSHA1: snapshot.gitSHA1,
                gitSHA256: snapshot.gitSHA256,
                gitMode: try gitMode(of: url, path: path)
            )
            manifest[path] = entry
            summaryRecords.append(SummaryRecord(
                path: path,
                gitMode: entry.gitMode,
                byteCount: entry.byteCount,
                sha256: entry.sha256
            ))
        }
        guard !errors.encountered else {
            throw DirectoryMoveError.unsafeFilesystemOperation("enumerate complete subtree")
        }
        return Manifest(
            rootPath: target.relativePath,
            entries: manifest,
            summary: summary(
                records: summaryRecords,
                rootPath: target.relativePath,
                totalBytes: subtreeBytes
            ),
            aggregatePathBytes: manifest.isEmpty ? 0 : manifest.keys
                .reduce(into: 0) { $0 += $1.utf8.count }
        )
    }

    private struct StableSnapshot {
        let byteCount: Int
        let sha256: String
        let gitSHA1: String
        let gitSHA256: String
    }

    /// Hashes every file through one stable descriptor; only bounded text is
    /// materialized for credential scanning.
    private static func stableSnapshot(
        url: URL,
        path: String,
        format: FileFormat?,
        maximumBytes: Int,
        protectedRoot: URL
    ) throws -> StableSnapshot {
        if format?.isTextual == true || format == nil {
            let snapshot = try BoundedFileReader.snapshot(
                fromCanonical: url.standardized,
                maximumBytes: maximumBytes,
                path: path,
                rejectHiddenDescendantsOf: protectedRoot
            )
            try PersistedFileSecurityPolicy.validateGitCandidate(
                snapshot.data,
                format: format,
                path: path
            )
            let digests = digests(data: snapshot.data)
            return StableSnapshot(
                byteCount: snapshot.data.count,
                sha256: digests.rawSHA256,
                gitSHA1: digests.gitSHA1,
                gitSHA256: digests.gitSHA256
            )
        }

        let captured = try BoundedFileReader.withStableFileDescriptor(
            fromCanonical: url.standardized,
            maximumBytes: maximumBytes,
            path: path,
            rejectHiddenDescendantsOf: protectedRoot
        ) { descriptor, initialBytes in
            var rawDigest = SHA256()
            var gitSHA1 = Insecure.SHA1()
            var gitSHA256 = SHA256()
            let header = Data("blob \(initialBytes)\0".utf8)
            gitSHA1.update(data: header)
            gitSHA256.update(data: header)
            var byteCount = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                byteCount += count
                let data = Data(buffer.prefix(count))
                rawDigest.update(data: data)
                gitSHA1.update(data: data)
                gitSHA256.update(data: data)
            }
            return (
                byteCount,
                rawDigest.finalize(),
                gitSHA1.finalize(),
                gitSHA256.finalize()
            )
        }
        guard captured.value.0 == captured.metadata.byteCount else {
            throw BoundedFileReader.ReadError.changedDuringRead
        }
        return StableSnapshot(
            byteCount: captured.value.0,
            sha256: hex(captured.value.1),
            gitSHA1: hex(captured.value.2),
            gitSHA256: hex(captured.value.3)
        )
    }

    private static func digests(
        data: Data
    ) -> (rawSHA256: String, gitSHA1: String, gitSHA256: String) {
        let header = Data("blob \(data.count)\0".utf8)
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        sha1.update(data: header)
        sha1.update(data: data)
        sha256.update(data: header)
        sha256.update(data: data)
        return (
            hex(SHA256.hash(data: data)),
            hex(sha1.finalize()),
            hex(sha256.finalize())
        )
    }

    private static func hex<Digest: Sequence>(_ digest: Digest) -> String
    where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func gitMode(of url: URL, path: String) throws -> String {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw DirectoryMoveError.unsafeFilesystemOperation(
                "inspect file mode for \(path)"
            )
        }
        // Git's regular-file mode records only its owner-execute convention;
        // group/other execute bits alone remain a 100644 index entry.
        return metadata.st_mode & S_IXUSR == 0 ? "100644" : "100755"
    }

    private struct SummaryRecord {
        let path: String
        let gitMode: String
        let byteCount: Int
        let sha256: String
    }

    private static func summary(
        records: [SummaryRecord],
        rootPath: String,
        totalBytes: Int
    ) -> Manifest.Summary {
        var digest = SHA256()
        let sorted = records.sorted {
            $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
        for record in sorted {
            let relative = String(record.path.dropFirst(rootPath.count + 1))
            update(&digest, field: Data(relative.utf8))
            update(&digest, field: Data(record.gitMode.utf8))
            var bytes = UInt64(record.byteCount).bigEndian
            update(&digest, field: Data(bytes: &bytes, count: MemoryLayout.size(ofValue: bytes)))
            update(&digest, field: Data(record.sha256.utf8))
        }
        return Manifest.Summary(
            digest: hex(digest.finalize()),
            entryCount: records.count,
            totalBytes: totalBytes
        )
    }

    private static func update(_ digest: inout SHA256, field: Data) {
        var count = UInt64(field.count).bigEndian
        digest.update(data: Data(bytes: &count, count: MemoryLayout.size(ofValue: count)))
        digest.update(data: field)
    }

    private static func relativePath(
        _ url: URL,
        target: NotesDirectoryTarget,
        depth: Int
    ) -> String {
        guard depth > 0, url.pathComponents.count >= depth else {
            return target.relativePath + "/" + url.lastPathComponent
        }
        let suffix = url.pathComponents.suffix(depth).joined(separator: "/")
        return target.relativePath + "/" + suffix
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
