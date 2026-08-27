import Foundation

struct SearchDocument: Sendable {
    let path: String
    let format: FileFormat
    let revision: FileRevision?
    let atoms: [SearchAtom]
    let failure: DiscoveryCoverage.Reason?
}

protocol VaultSearchAtomSource: Sendable {
    var searchableFormats: [FileFormat] { get }

    @discardableResult
    func scan(
        _ request: VaultSearchRequest,
        consume: @escaping @Sendable (SearchDocument) async throws -> Void
    ) async throws -> Set<FileFormat>
}

/// Enumerates one vault area and delegates file representation to atom providers.
struct SearchCorpusBuilder: VaultSearchAtomSource, Sendable {
    private let vaultPath: String
    private let capabilities: FileCapabilities
    private let captureStore: SearchCaptureStore
    private let access: any VaultAccessCoordinating
    private let textProvider: any SearchAtomProvider
    private let canvasProvider: any SearchAtomProvider
    private let customProviders: [FileFormat: any SearchAtomProvider]
    private let maximumTraversalPathBytes: Int
    private let maximumCandidateMetadataBytes: Int

    init(
        vaultPath: String,
        capabilities: FileCapabilities,
        captureStore: SearchCaptureStore,
        access: any VaultAccessCoordinating,
        textProvider: any SearchAtomProvider = TextSearchAtomProvider(),
        canvasProvider: any SearchAtomProvider = CanvasSearchAtomProvider(),
        customProviders: [FileFormat: any SearchAtomProvider] = [:],
        maximumTraversalPathBytes: Int = 8 * 1_024 * 1_024,
        maximumCandidateMetadataBytes: Int = 8 * 1_024 * 1_024
    ) {
        precondition((0...8 * 1_024 * 1_024).contains(maximumTraversalPathBytes))
        precondition((0...8 * 1_024 * 1_024).contains(maximumCandidateMetadataBytes))
        self.maximumTraversalPathBytes = maximumTraversalPathBytes
        self.maximumCandidateMetadataBytes = maximumCandidateMetadataBytes
        self.vaultPath = vaultPath
        self.capabilities = capabilities
        self.captureStore = captureStore
        self.access = access
        self.textProvider = textProvider
        self.canvasProvider = canvasProvider
        self.customProviders = customProviders
    }

    /// Discovery and request validation use the same readable/provider intersection.
    var searchableFormats: [FileFormat] { searchableFormats(in: nil) }

    private func searchableFormats(in area: VaultArea?) -> [FileFormat] {
        capabilities.supportedFormats(for: .read, in: area).filter { provider(for: $0) != nil }
    }

    private enum CapturedInput: Sendable {
        case file(SearchCaptureSession.Entry)
        case failure(SearchDocument)
    }

    @discardableResult
    func scan(
        _ request: VaultSearchRequest,
        consume: @escaping @Sendable (SearchDocument) async throws -> Void
    ) async throws -> Set<FileFormat> {
        let readable = Set(searchableFormats(in: request.location))
        let unsupported = request.formats.filter { !readable.contains($0) }
        guard unsupported.isEmpty else {
            throw VaultSearchRequestError.unsupportedFormats(unsupported, location: request.location)
        }
        var selectedFormats = request.formats.isEmpty ? readable : Set(request.formats)
        if !request.tags.isEmpty || request.createdFrom != nil || request.createdThrough != nil {
            selectedFormats.formIntersection([.markdown])
        }
        let formats = selectedFormats
        try await captureStore.withCapture { session in
            let inputs = try await access.withRead {
                try await captureProtected(request, formats: formats, session: session)
            }
            let budget = SearchWorkBudget()
            for input in inputs {
                try Task.checkCancellation()
                switch input {
                case .failure(let failed):
                    try await consume(failed)
                case .file(let entry):
                    guard let provider = provider(for: entry.target.format) else { continue }
                    let document: SearchDocument
                    do {
                        let atoms = try await provider.atoms(
                            for: entry.target,
                            loadSnapshot: { try await session.snapshot(entry) },
                            budget: budget
                        )
                        document = SearchDocument(
                            path: entry.target.relativePath, format: entry.target.format,
                            revision: entry.revision, atoms: atoms, failure: nil
                        )
                    } catch {
                        // Private capture corruption/IO and cancellation remain request failures.
                        guard let reason = DiscoveryFileFailure.reason(for: error) else { throw error }
                        document = SearchDocument(
                            path: entry.target.relativePath, format: entry.target.format,
                            revision: entry.revision, atoms: [], failure: reason
                        )
                    }
                    // No vault lease is held during extraction, ranking or result consumption.
                    try await consume(document)
                }
            }
        }
        return formats
    }

    private func captureProtected(
        _ request: VaultSearchRequest,
        formats: Set<FileFormat>,
        session: SearchCaptureSession
    ) async throws -> [CapturedInput] {
        let candidates = try candidateFiles(
            in: request.location, directory: request.directory, formats: formats
        )
        var captured: [CapturedInput] = []
        captured.reserveCapacity(candidates.count)
        for candidate in candidates {
            try Task.checkCancellation()
            let target = try ReadableFileTarget.resolve(
                path: candidate.path, format: candidate.format, vaultPath: vaultPath
            )
            do {
                captured.append(.file(try await session.capture(target)))
            } catch {
                guard let reason = DiscoveryFileFailure.reason(for: error) else { throw error }
                captured.append(.failure(SearchDocument(
                    path: candidate.path, format: candidate.format, revision: nil,
                    atoms: [], failure: reason
                )))
            }
        }
        return captured
    }

    private func provider(for format: FileFormat) -> (any SearchAtomProvider)? {
        if let custom = customProviders[format] { return custom }
        if format == .canvas { return canvasProvider }
        return format.isTextual ? textProvider : nil
    }

    private func candidateFiles(
        in location: VaultArea,
        directory: String?,
        formats: Set<FileFormat>
    ) throws -> [(path: String, format: FileFormat)] {
        let root = URL(fileURLWithPath: vaultPath, isDirectory: true)
            .appendingPathComponent(location.rawValue, isDirectory: true)
        guard let selected = try selectedRoot(location: location, directory: directory) else { return [] }
        var result: [(String, FileFormat)] = []
        var scannedEntries = 0
        var traversalPathBytes = 0
        var candidateMetadataBytes = 0
        try collectFiles(
            below: selected,
            areaRoot: root,
            location: location,
            formats: formats,
            scannedEntries: &scannedEntries,
            traversalPathBytes: &traversalPathBytes,
            candidateMetadataBytes: &candidateMetadataBytes,
            result: &result
        )
        return result.sorted {
            $0.0 == $1.0 ? $0.1.rawValue < $1.1.rawValue : $0.0 < $1.0
        }
    }

    private func selectedRoot(location: VaultArea, directory: String?) throws -> URL? {
        let relative = directory.map { location.rawValue + "/" + $0 } ?? location.rawValue
        _ = try PathValidator.resolve(relativePath: relative, root: vaultPath)
        guard !PathValidator.containsSymbolicLinkComponent(relativePath: relative, root: vaultPath)
        else { throw PathValidationError.pathChangedSinceValidation(relative) }
        var current = URL(fileURLWithPath: vaultPath, isDirectory: true)
        for component in relative.split(separator: "/") {
            guard !component.hasPrefix(".") else { throw VaultSearchRequestError.invalidScope }
            current.appendPathComponent(String(component), isDirectory: true)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            } catch {
                let cocoa = error as NSError
                if cocoa.domain == NSCocoaErrorDomain,
                   [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoa.code) {
                    if directory == nil { return nil }
                    throw VaultSearchRequestError.directoryNotFound
                }
                throw error
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw VaultSearchRequestError.invalidScope
            }
            let values = try current.resourceValues(forKeys: [.isHiddenKey, .isPackageKey])
            guard values.isHidden != true, values.isPackage != true else {
                throw VaultSearchRequestError.invalidScope
            }
        }
        return current
    }

    private func collectFiles(
        below directory: URL,
        areaRoot: URL,
        location: VaultArea,
        formats: Set<FileFormat>,
        scannedEntries: inout Int,
        traversalPathBytes: inout Int,
        candidateMetadataBytes: inout Int,
        result: inout [(String, FileFormat)]
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
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
            ),
            reserveEntry: { child in
                let bytes = child.path.utf8.count
                guard bytes <= maximumTraversalPathBytes - traversalPathBytes else {
                    throw VaultSearchRequestError.workBudgetExceeded
                }
                traversalPathBytes += bytes
            }
        )
        for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true || values.isPackage == true { continue }
            if values.isDirectory == true {
                try collectFiles(
                    below: child,
                    areaRoot: areaRoot,
                    location: location,
                    formats: formats,
                    scannedEntries: &scannedEntries,
                    traversalPathBytes: &traversalPathBytes,
                    candidateMetadataBytes: &candidateMetadataBytes,
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
            let relativePath = "\(location.rawValue)/\(suffix)"
            let bytes = SearchCaptureSession.manifestEntryBytes(
                relativePath: relativePath, absolutePath: filePath, format: format
            )
            guard bytes <= maximumCandidateMetadataBytes - candidateMetadataBytes else {
                throw VaultSearchRequestError.workBudgetExceeded
            }
            candidateMetadataBytes += bytes
            result.append((relativePath, format))
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
