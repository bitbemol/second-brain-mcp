import CryptoKit
import Foundation

/// Bounded descriptor-only file browser kept separate from content search.
struct VaultFileListingService: FileListingService, Sendable {
    private let vaultPath: String
    private let capabilities: FileCapabilities
    private let access: any VaultAccessCoordinating
    private let maximumScannedEntries: Int

    init(
        vaultPath: String,
        capabilities: FileCapabilities,
        access: any VaultAccessCoordinating,
        maximumScannedEntries: Int = FileListingRequestLimits.maximumScannedEntries
    ) {
        self.vaultPath = vaultPath
        self.capabilities = capabilities
        self.access = access
        self.maximumScannedEntries = maximumScannedEntries
    }

    func list(_ request: ListFilesRequest) async throws -> ListFilesResult {
        try await access.withRead {
            try listUnderLease(request)
        }
    }

    private func listUnderLease(_ request: ListFilesRequest) throws -> ListFilesResult {
        let normalized = try validatedRequest(request)
        let requestHash = try ListFilesCursorCodec.requestHash(normalized)
        let continuation = try normalized.cursor.map {
            try ListFilesCursorCodec.decode($0, requestHash: requestHash)
        }
        let areaRoot = URL(fileURLWithPath: vaultPath, isDirectory: true)
            .appendingPathComponent(normalized.area.rawValue, isDirectory: true)
            .standardizedFileURL
        guard let selectedRoot = try selectedRoot(
            area: normalized.area,
            directory: normalized.directory
        ) else {
            guard continuation == nil else { throw FileListingError.staleCursor }
            return ListFilesResult(files: [], nextCursor: nil)
        }

        var hasher = SHA256()
        var page: [ListedFile] = []
        page.reserveCapacity(normalized.limit + 1)
        var scannedEntries = 0
        var observedContinuation = continuation == nil
        try collect(
            below: selectedRoot,
            areaRoot: areaRoot,
            request: normalized,
            continuationPath: continuation?.lastPath,
            observedContinuation: &observedContinuation,
            scannedEntries: &scannedEntries,
            hasher: &hasher,
            page: &page
        )
        guard observedContinuation else { throw FileListingError.invalidCursor }

        let corpusHash = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        if let continuation, continuation.corpusHash != corpusHash {
            throw FileListingError.staleCursor
        }

        let files = Array(page.prefix(normalized.limit))
        let nextCursor: String?
        if page.count > normalized.limit, let last = files.last {
            nextCursor = try ListFilesCursorCodec.encode(
                requestHash: requestHash,
                corpusHash: corpusHash,
                lastPath: last.path
            )
        } else {
            nextCursor = nil
        }
        return ListFilesResult(files: files, nextCursor: nextCursor)
    }

    private func validatedRequest(_ request: ListFilesRequest) throws -> ListFilesRequest {
        guard request.limit > 0,
              request.limit <= FileListingRequestLimits.maximumResults else {
            throw FileListingError.invalidRequest(
                "limit must be between 1 and \(FileListingRequestLimits.maximumResults)"
            )
        }
        if let cursor = request.cursor,
           cursor.utf8.count > FileListingRequestLimits.maximumCursorBytes {
            throw FileListingError.invalidCursor
        }
        let directory: String?
        if let raw = request.directory {
            guard !raw.isEmpty,
                  raw.utf8.count <= FileListingRequestLimits.maximumDirectoryBytes,
                  raw != ".",
                  !raw.hasPrefix("/"),
                  !raw.hasSuffix("/") else {
                throw FileListingError.invalidRequest(
                    "directory must be a non-empty area-relative path without leading or trailing slash"
                )
            }
            directory = raw
        } else {
            directory = nil
        }
        let readable = Set(
            capabilities.supportedFormats(for: .read, in: request.area)
        )
        let formats = request.formats.isEmpty
            ? readable.sorted { $0.rawValue < $1.rawValue }
            : Array(Set(request.formats)).sorted { $0.rawValue < $1.rawValue }
        guard formats.allSatisfy(readable.contains) else {
            throw FileListingError.invalidRequest(
                "formats must be readable in \(request.area.rawValue)/"
            )
        }
        return ListFilesRequest(
            area: request.area,
            directory: directory,
            recursive: request.recursive,
            formats: formats,
            limit: request.limit,
            cursor: request.cursor
        )
    }

    private func selectedRoot(area: VaultArea, directory: String?) throws -> URL? {
        let relative = directory.map { area.rawValue + "/" + $0 } ?? area.rawValue
        _ = try PathValidator.resolve(relativePath: relative, root: vaultPath)
        guard !PathValidator.containsSymbolicLinkComponent(
            relativePath: relative, root: vaultPath
        ) else {
            throw PathValidationError.pathChangedSinceValidation(relative)
        }
        var current = URL(fileURLWithPath: vaultPath, isDirectory: true)
        for component in relative.split(separator: "/") {
            guard !component.hasPrefix(".") else {
                throw FileListingError.invalidRequest("directory must select a visible directory")
            }
            current.appendPathComponent(String(component), isDirectory: true)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            } catch {
                let cocoa = error as NSError
                if cocoa.domain == NSCocoaErrorDomain,
                   [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoa.code) {
                    if directory == nil { return nil }
                    throw FileListingError.directoryNotFound
                }
                throw error
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw FileListingError.invalidRequest("directory must select a visible directory")
            }
            let values = try current.resourceValues(forKeys: [.isHiddenKey, .isPackageKey])
            guard values.isHidden != true, values.isPackage != true else {
                throw FileListingError.invalidRequest("directory must select a visible directory")
            }
        }
        return current
    }

    private func collect(
        below directory: URL,
        areaRoot: URL,
        request: ListFilesRequest,
        continuationPath: String?,
        observedContinuation: inout Bool,
        scannedEntries: inout Int,
        hasher: inout SHA256,
        page: inout [ListedFile]
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
        ]
        let children = try BoundedDirectoryChildren.urls(
            below: directory,
            resourceKeys: keys,
            maximumEntries: maximumScannedEntries,
            scannedEntries: &scannedEntries,
            limitError: FileListingError.scanLimitExceeded
        )

        for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true || values.isPackage == true { continue }
            if values.isDirectory == true {
                if request.recursive {
                    try collect(
                        below: child,
                        areaRoot: areaRoot,
                        request: request,
                        continuationPath: continuationPath,
                        observedContinuation: &observedContinuation,
                        scannedEntries: &scannedEntries,
                        hasher: &hasher,
                        page: &page
                    )
                }
                continue
            }
            guard values.isRegularFile == true,
                  let format = request.formats.first(where: {
                      $0.accepts(path: child.path)
                  }) else {
                continue
            }

            let rootPath = areaRoot.path
            let childPath = child.standardizedFileURL.path
            guard childPath.hasPrefix(rootPath + "/") else { continue }
            let suffix = childPath.dropFirst(rootPath.count + 1)
            let relativePath = "\(request.area.rawValue)/\(suffix)"
            let target = try ReadableFileTarget.resolve(
                path: relativePath,
                format: format,
                vaultPath: vaultPath
            )
            let metadata = try VaultFileInspector.stableMetadata(
                target,
                vaultRoot: URL(fileURLWithPath: vaultPath, isDirectory: true)
            )

            let descriptor = [
                relativePath,
                format.rawValue,
                String(metadata.byteCount),
                metadata.deviceID.map(String.init) ?? "",
                metadata.inode.map(String.init) ?? "",
                metadata.modificationNanoseconds.map(String.init) ?? "",
                metadata.changeSeconds.map(String.init) ?? "",
                metadata.changeNanoseconds.map(String.init) ?? "",
            ].joined(separator: "\u{0}") + "\n"
            hasher.update(data: Data(descriptor.utf8))
            if relativePath == continuationPath {
                observedContinuation = true
                continue
            }
            guard observedContinuation,
                  page.count <= request.limit else {
                continue
            }
            page.append(ListedFile(
                path: relativePath,
                format: format,
                byteCount: metadata.byteCount,
                modifiedAt: metadata.modificationDate.map(Self.timestamp)
            ))
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }
}
