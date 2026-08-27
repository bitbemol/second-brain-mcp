import Foundation

// MARK: - Vault link corpus

struct VaultLinkFile: Codable, Hashable, Sendable {
    let path: String
    let format: FileFormat
}

struct VaultLinkCorpusBuilder: Sendable {
    private let vaultPath: String
    private let capabilities: FileCapabilities
    private let store: VaultCRUDStore

    init(
        vaultPath: String,
        capabilities: FileCapabilities,
        store: VaultCRUDStore
    ) {
        self.vaultPath = vaultPath
        self.capabilities = capabilities
        self.store = store
    }

    func files() throws -> [VaultLinkFile] {
        var result: [VaultLinkFile] = []
        var scannedEntries = 0
        for area in VaultArea.allCases {
            try Task.checkCancellation()
            let formats = capabilities.supportedFormats(for: .read, in: area)
                .sorted { $0.rawValue < $1.rawValue }
            guard !formats.isEmpty else { continue }
            guard let root = try visibleAreaRoot(area) else { continue }
            try collectFiles(
                below: root,
                areaRoot: root,
                area: area,
                formats: formats,
                scannedEntries: &scannedEntries,
                result: &result
            )
        }
        return result.sorted {
            $0.path == $1.path
                ? $0.format.rawValue < $1.format.rawValue
                : $0.path < $1.path
        }
    }

    /// Namespace-only queries still require a real visible structural root.
    private func visibleAreaRoot(_ area: VaultArea) throws -> URL? {
        _ = try PathValidator.resolve(relativePath: area.rawValue, root: vaultPath)
        guard !PathValidator.containsSymbolicLinkComponent(relativePath: area.rawValue, root: vaultPath)
        else { throw PathValidationError.pathChangedSinceValidation(area.rawValue) }
        let root = URL(fileURLWithPath: vaultPath, isDirectory: true)
            .appendingPathComponent(area.rawValue, isDirectory: true)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        } catch {
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoa.code) {
                return nil
            }
            throw error
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw LinkQueryError.invalidTarget
        }
        let values = try root.resourceValues(forKeys: [.isHiddenKey, .isPackageKey])
        guard values.isHidden != true, values.isPackage != true else {
            throw LinkQueryError.invalidTarget
        }
        return root
    }

    /// Captures one selected source; callers consume and release it before requesting another.
    func snapshot(
        _ file: VaultLinkFile,
        maximumBytes: Int,
        didReadBytes: BoundedFileReader.ReadObserver? = nil
    ) async throws -> FileSnapshot {
        let target = try ReadableFileTarget.resolve(
            path: file.path, format: .markdown, vaultPath: vaultPath
        )
        return try await store.snapshot(
            target, maximumBytes: maximumBytes, rejectHiddenComponents: true,
            didReadBytes: didReadBytes
        )
    }

    private func collectFiles(
        below directory: URL,
        areaRoot: URL,
        area: VaultArea,
        formats: [FileFormat],
        scannedEntries: inout Int,
        result: inout [VaultLinkFile]
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey,
        ]
        let children = try BoundedDirectoryChildren.urls(
            below: directory,
            resourceKeys: keys,
            maximumEntries: LinkQueryExecutionLimits.maximumScannedEntries,
            scannedEntries: &scannedEntries,
            limitError: LinkQueryError.corpusTooLarge(
                files: result.count,
                bytes: 0
            )
        )
        for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            if values.isHidden == true || values.isSymbolicLink == true || values.isPackage == true {
                continue
            }
            if values.isDirectory == true {
                try collectFiles(
                    below: child,
                    areaRoot: areaRoot,
                    area: area,
                    formats: formats,
                    scannedEntries: &scannedEntries,
                    result: &result
                )
                continue
            }
            guard values.isRegularFile == true,
                  let format = formats.first(where: { $0.accepts(path: child.path) })
            else {
                continue
            }
            let rootPath = areaRoot.standardizedFileURL.path
            let filePath = child.standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else { continue }
            let suffix = filePath.dropFirst(rootPath.count + 1)
            result.append(VaultLinkFile(
                path: "\(area.rawValue)/\(suffix)",
                format: format
            ))
            guard result.count <= LinkQueryExecutionLimits.maximumIndexedFiles else {
                throw LinkQueryError.corpusTooLarge(files: result.count, bytes: 0)
            }
        }
    }
}
