import Foundation

// MARK: - Vault link corpus

struct VaultLinkFile: Codable, Hashable, Sendable {
    let path: String
    let format: FileFormat
}

struct VaultLinkDocument: Sendable {
    let file: VaultLinkFile
    let text: String
    let revision: String
}

enum VaultLinkMarkdownScope: Sendable {
    case none
    case one(String)
    case all
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
            let root = URL(fileURLWithPath: vaultPath, isDirectory: true)
                .appendingPathComponent(area.rawValue, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
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

    func markdownDocuments(
        from files: [VaultLinkFile],
        scope: VaultLinkMarkdownScope
    ) async throws -> [VaultLinkDocument] {
        let selected: [VaultLinkFile]
        switch scope {
        case .none:
            return []
        case .one(let path):
            selected = files.filter { $0.path == path && $0.format == .markdown }
        case .all:
            selected = files.filter { $0.format == .markdown && $0.path.hasPrefix("notes/") }
        }

        var documents: [VaultLinkDocument] = []
        documents.reserveCapacity(selected.count)
        var totalBytes = 0
        for file in selected {
            try Task.checkCancellation()
            let remaining = LinkQueryLimits.maximumMarkdownBytes - totalBytes
            guard remaining > 0 else {
                throw LinkQueryError.corpusTooLarge(files: files.count, bytes: totalBytes)
            }
            let target = try ReadableFileTarget.resolve(
                path: file.path,
                format: .markdown,
                vaultPath: vaultPath
            )
            let snapshot: FileSnapshot
            do {
                snapshot = try await store.snapshot(
                    target,
                    maximumBytes: remaining,
                    rejectHiddenComponents: true
                )
            } catch is FileResourcePolicy.Violation {
                throw LinkQueryError.corpusTooLarge(
                    files: files.count,
                    bytes: LinkQueryLimits.maximumMarkdownBytes + 1
                )
            }
            totalBytes += snapshot.data.count
            guard let text = String(data: snapshot.data, encoding: .utf8) else {
                throw SearchAtomProviderError.invalidUTF8(file.path)
            }
            documents.append(VaultLinkDocument(
                file: file,
                text: text,
                revision: snapshot.revision.description
            ))
        }
        return documents
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
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey,
        ]
        let children = try BoundedDirectoryChildren.urls(
            below: directory,
            resourceKeys: keys,
            maximumEntries: SearchRequestLimits.maximumScannedEntries,
            scannedEntries: &scannedEntries,
            limitError: LinkQueryError.corpusTooLarge(
                files: result.count,
                bytes: 0
            )
        )
        for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            if values.isHidden == true || values.isSymbolicLink == true { continue }
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
            guard result.count <= LinkQueryLimits.maximumIndexedFiles else {
                throw LinkQueryError.corpusTooLarge(files: result.count, bytes: 0)
            }
        }
    }
}
