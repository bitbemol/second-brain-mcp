import Foundation

protocol VaultSearchAtomSource: Sendable {
    func atoms(in location: VaultArea) async throws -> [SearchAtom]
}

/// Enumerates one vault area and delegates file representation to atom providers.
struct SearchCorpusBuilder: VaultSearchAtomSource, Sendable {
    private let vaultPath: String
    private let capabilities: FileCapabilities
    private let store: VaultCRUDStore
    private let operations: VaultOperationCoordinator
    private let textProvider: any SearchAtomProvider
    private let customProviders: [FileFormat: any SearchAtomProvider]

    init(
        vaultPath: String,
        capabilities: FileCapabilities,
        store: VaultCRUDStore,
        operations: VaultOperationCoordinator,
        textProvider: any SearchAtomProvider = TextSearchAtomProvider(),
        customProviders: [FileFormat: any SearchAtomProvider] = [:]
    ) {
        self.vaultPath = vaultPath
        self.capabilities = capabilities
        self.store = store
        self.operations = operations
        self.textProvider = textProvider
        self.customProviders = customProviders
    }

    func atoms(in location: VaultArea) async throws -> [SearchAtom] {
        let readable = Set(
            capabilities.supportedFormats(for: .read, in: location)
        )
        let formats = readable.filter {
            $0.isTextual || customProviders[$0] != nil
        }
        guard !formats.isEmpty else { return [] }

        let candidates = try candidateFiles(in: location, formats: formats)
        var result: [SearchAtom] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let target = try ReadableFileTarget.resolve(
                path: candidate.path,
                format: candidate.format,
                vaultPath: vaultPath
            )
            let snapshot: FileSnapshot
            if location == .notes {
                snapshot = try await operations.withRead(target: target) {
                    try await store.snapshot(
                        target,
                        maximumBytes: target.format.maximumFileBytes,
                        rejectHiddenComponents: true
                    )
                }
            } else {
                snapshot = try await store.snapshot(
                    target,
                    maximumBytes: target.format.maximumFileBytes,
                    rejectHiddenComponents: true
                )
            }
            guard let provider = provider(for: target.format) else { continue }
            result.append(contentsOf: try await provider.atoms(
                for: target,
                snapshot: snapshot
            ))
        }
        return result
    }

    private func provider(for format: FileFormat) -> (any SearchAtomProvider)? {
        customProviders[format] ?? (format.isTextual ? textProvider : nil)
    }

    private func candidateFiles(
        in location: VaultArea,
        formats: Set<FileFormat>
    ) throws -> [(path: String, format: FileFormat)] {
        let root = URL(fileURLWithPath: vaultPath, isDirectory: true)
            .appendingPathComponent(location.rawValue, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var result: [(String, FileFormat)] = []
        try collectFiles(
            below: root,
            areaRoot: root,
            location: location,
            formats: formats,
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
        result: inout [(String, FileFormat)]
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        for child in children.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                try collectFiles(
                    below: child,
                    areaRoot: areaRoot,
                    location: location,
                    formats: formats,
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
        }
    }
}
