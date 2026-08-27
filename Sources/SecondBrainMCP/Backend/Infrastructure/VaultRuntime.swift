import Foundation

/// Fully initialized backend dependencies for one vault process.
struct VaultRuntime: Sendable {
    /// Routed generic file service.
    let files: any FileCRUDService
    /// Atomic supported-file and recursive notes-directory moves.
    let paths: any PathMoveService
    /// Bounded read-only search service.
    let search: any VaultSearchService
    /// Bounded Obsidian link-resolution and traversal service.
    let links: any VaultLinkQueryService
    /// Bounded descriptor-only file browsing service.
    let listing: any FileListingService
    /// Immutable capability projection shared with MCP discovery.
    let capabilities: FileCapabilities
    /// Deferred writable-startup recovery, kept separate from graph construction.
    private let startupRecovery: @Sendable () async throws -> Void

    /// Prepares permitted process state and constructs the backend graph.
    static func bootstrap(
        vaultPath: String,
        readOnly: Bool = false,
        injectedAccess: (any VaultAccessCoordinating)? = nil
    ) async throws -> VaultRuntime {
        let dataDirectory = try VaultDataDirectory.prepare(vaultPath: vaultPath)
        let access = injectedAccess ?? VaultAccessCoordinator(
            lockURL: dataDirectory.lockDirectoryURL
                .appendingPathComponent("vault-access.lock")
        )
        let versioning = try GitRepository(
            repositoryURL: URL(fileURLWithPath: vaultPath, isDirectory: true)
        )
        let startupRecovery: @Sendable () async throws -> Void
        if readOnly {
            startupRecovery = { @Sendable in }
        } else {
            startupRecovery = { @Sendable in
                try await access.withMutation {
                    try await versioning.recordSnapshot()
                }
            }
        }

        let store = VaultCRUDStore(vaultPath: vaultPath)
        let mutations = VaultMutationExecutor(versioning: versioning)
        let limits = ImageLimits.default
        let externalSources = ExternalFileSourceValidator(vaultPath: vaultPath)
        let imageReader = ImageReader(
            encoder: CoreGraphicsImageEncoder(),
            limits: limits
        )
        let imageImporter = ImageImporter(
            sourceValidator: externalSources,
            encoder: CoreGraphicsImageEncoder(),
            limits: limits
        )
        let pdfAdmission = PDFReadAdmission(
            processLock: POSIXAdvisoryFileLock(
                url: dataDirectory.lockDirectoryURL
                    .appendingPathComponent("pdf-reference-reads.lock")
            )
        )
        let pdfReader = PDFReader(admission: pdfAdmission)
        let catalog = FileFormatCatalogFactory.build(
            imageReader: imageReader,
            imageImporter: imageImporter,
            videoImporter: VideoImporter(
                sourceValidator: externalSources,
                encoder: AVFoundationVideoEncoder()
            ),
            pdfReader: pdfReader
        )
        let capabilities = catalog.capabilities()
        let files = VaultFileService(
            vaultPath: vaultPath,
            catalog: catalog,
            store: store,
            mutations: mutations,
            access: access,
            metadataReader: FileMetadataReader(),
            readOnly: readOnly
        )
        let paths = VaultPathMoveService(
            vaultPath: vaultPath,
            supportedFileFormats: Set(
                capabilities.supportedFormats(for: .delete, in: .notes)
            ),
            versioning: versioning,
            access: access,
            readOnly: readOnly
        )
        let searchCapture = SearchCaptureStore(
            directory: dataDirectory.rootURL.appendingPathComponent("search-capture", isDirectory: true),
            vaultRoot: URL(fileURLWithPath: vaultPath),
            processLock: POSIXAdvisoryFileLock(
                url: dataDirectory.lockDirectoryURL.appendingPathComponent("search-capture.lock")
            )
        )
        let searchSource = SearchCorpusBuilder(
            vaultPath: vaultPath,
            capabilities: capabilities,
            captureStore: searchCapture,
            access: access,
            customProviders: [
                .pdf: PDFSearchAtomProvider(
                    cacheRoot: dataDirectory.searchIndexDirectoryURL,
                    admission: pdfAdmission
                ),
            ]
        )
        let search = VaultSearchEngine(source: searchSource)
        let links = VaultLinkQueryEngine(
            vaultPath: vaultPath,
            capabilities: capabilities,
            store: store,
            access: access
        )
        let listing = VaultFileListingService(
            vaultPath: vaultPath,
            capabilities: capabilities,
            access: access
        )
        return VaultRuntime(
            files: files,
            paths: paths,
            search: search,
            links: links,
            listing: listing,
            capabilities: capabilities,
            startupRecovery: startupRecovery
        )
    }

    /// Snapshots note changes left pending before this process started.
    func recoverPendingChanges() async throws {
        try await startupRecovery()
    }
}
