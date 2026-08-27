import Foundation

protocol VaultSearchAtomSource: Sendable {
    func atoms(in location: VaultArea) async throws -> [SearchAtom]
}

/// Enumerates one vault area and delegates file representation to atom providers.
struct SearchCorpusBuilder: VaultSearchAtomSource, Sendable {
    private let vaultPath: String
    private let capabilities: FileCapabilities
    private let store: VaultCRUDStore
    private let access: any VaultAccessCoordinating
    private let textProvider: any SearchAtomProvider
    private let canvasProvider: any SearchAtomProvider
    private let customProviders: [FileFormat: any SearchAtomProvider]

    init(
        vaultPath: String,
        capabilities: FileCapabilities,
        store: VaultCRUDStore,
        access: any VaultAccessCoordinating,
        textProvider: any SearchAtomProvider = TextSearchAtomProvider(),
        canvasProvider: any SearchAtomProvider = CanvasSearchAtomProvider(),
        customProviders: [FileFormat: any SearchAtomProvider] = [:]
    ) {
        self.vaultPath = vaultPath
        self.capabilities = capabilities
        self.store = store
        self.access = access
        self.textProvider = textProvider
        self.canvasProvider = canvasProvider
        self.customProviders = customProviders
    }

    func atoms(in location: VaultArea) async throws -> [SearchAtom] {
        try await access.withRead {
            try await buildAtoms(in: location)
        }
    }

    private func buildAtoms(in location: VaultArea) async throws -> [SearchAtom] {
        let readable = Set(
            capabilities.supportedFormats(for: .read, in: location)
        )
        let formats = readable.filter {
            $0.isTextual || customProviders[$0] != nil
        }
        guard !formats.isEmpty else { return [] }

        let candidates = try candidateFiles(in: location, formats: formats)
        var result: [SearchAtom] = []
        var totalBytes = 0
        for candidate in candidates {
            try Task.checkCancellation()
            let target = try ReadableFileTarget.resolve(
                path: candidate.path,
                format: candidate.format,
                vaultPath: vaultPath
            )
            guard let provider = provider(for: target.format) else { continue }
            let remainingBytes = SearchRequestLimits.maximumCorpusBytes - totalBytes
            guard remainingBytes > 0 else {
                throw VaultSearchRequestError.corpusTooLarge(
                    files: candidates.count,
                    bytes: totalBytes,
                    atoms: result.count
                )
            }
            do {
                let snapshot = try await store.snapshot(
                    target,
                    maximumBytes: min(target.format.maximumFileBytes, remainingBytes),
                    rejectHiddenComponents: true
                )
                totalBytes += snapshot.data.count
                let atoms = try await provider.atoms(
                    for: target,
                    snapshot: snapshot
                )
                guard atoms.count <= SearchRequestLimits.maximumAtoms - result.count else {
                    throw VaultSearchRequestError.corpusTooLarge(
                        files: candidates.count,
                        bytes: totalBytes,
                        atoms: result.count + atoms.count
                    )
                }
                result.append(contentsOf: atoms)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as VaultSearchRequestError {
                throw error
            } catch let error as PathValidationError {
                throw error
            } catch let error as FileRoutingError {
                throw error
            } catch is FileResourcePolicy.Violation
                where remainingBytes < target.format.maximumFileBytes {
                throw VaultSearchRequestError.corpusTooLarge(
                    files: candidates.count,
                    bytes: SearchRequestLimits.maximumCorpusBytes + 1,
                    atoms: result.count
                )
            } catch {
                // One malformed, oversized, unreadable, or raced file must not
                // make every healthy file in the selected area undiscoverable.
                continue
            }
        }
        return result
    }

    private func provider(for format: FileFormat) -> (any SearchAtomProvider)? {
        if let custom = customProviders[format] { return custom }
        if format == .canvas { return canvasProvider }
        return format.isTextual ? textProvider : nil
    }

    private func candidateFiles(
        in location: VaultArea,
        formats: Set<FileFormat>
    ) throws -> [(path: String, format: FileFormat)] {
        let root = URL(fileURLWithPath: vaultPath, isDirectory: true)
            .appendingPathComponent(location.rawValue, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var result: [(String, FileFormat)] = []
        var scannedEntries = 0
        try collectFiles(
            below: root,
            areaRoot: root,
            location: location,
            formats: formats,
            scannedEntries: &scannedEntries,
            result: &result
        )
        return result.sorted {
            $0.0 == $1.0 ? $0.1.rawValue < $1.1.rawValue : $0.0 < $1.0
        }
    }

    private func collectFiles(
        below directory: URL,
        areaRoot: URL,
        location: VaultArea,
        formats: Set<FileFormat>,
        scannedEntries: inout Int,
        result: inout [(String, FileFormat)]
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        let children = try BoundedDirectoryChildren.urls(
            below: directory,
            resourceKeys: keys,
            maximumEntries: SearchRequestLimits.maximumScannedEntries,
            scannedEntries: &scannedEntries,
            limitError: VaultSearchRequestError.corpusTooLarge(
                files: result.count,
                bytes: 0,
                atoms: 0
            )
        )
        for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                try collectFiles(
                    below: child,
                    areaRoot: areaRoot,
                    location: location,
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
            result.append(("\(location.rawValue)/\(suffix)", format))
            guard result.count <= SearchRequestLimits.maximumIndexedFiles else {
                throw VaultSearchRequestError.corpusTooLarge(
                    files: result.count,
                    bytes: 0,
                    atoms: 0
                )
            }
        }
    }
}
