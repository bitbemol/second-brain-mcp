import Foundation

/// Fully initialized backend dependencies for one vault process.
struct VaultRuntime: Sendable {
    /// Routed generic file service.
    let files: any FileCRUDService
    /// Atomic recursive notes-directory moves.
    let directories: any DirectoryMoveService
    /// Bounded read-only search service.
    let search: any VaultSearchService
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
        let catalog = FileFormatCatalogFactory.build(
            imageReader: imageReader,
            imageImporter: imageImporter,
            videoImporter: VideoImporter(
                sourceValidator: externalSources,
                encoder: AVFoundationVideoEncoder()
            ),
            pdfReader: PDFReader(admission: pdfAdmission)
        )
        let files = VaultFileService(
            vaultPath: vaultPath,
            catalog: catalog,
            store: store,
            mutations: mutations,
            access: access,
            readOnly: readOnly
        )
        let directories = VaultDirectoryMoveService(
            vaultPath: vaultPath,
            versioning: versioning,
            access: access,
            readOnly: readOnly
        )
        let capabilities = catalog.capabilities()
        let searchSource = SearchCorpusBuilder(
            vaultPath: vaultPath,
            capabilities: capabilities,
            store: store,
            access: access,
            customProviders: [
                .pdf: PDFSearchAtomProvider(
                    cacheRoot: dataDirectory.searchIndexDirectoryURL,
                    admission: pdfAdmission
                ),
            ]
        )
        let search = VaultSearchEngine(source: searchSource)
        return VaultRuntime(
            files: files,
            directories: directories,
            search: search,
            capabilities: capabilities,
            startupRecovery: startupRecovery
        )
    }

    /// Snapshots note changes left pending before this process started.
    func recoverPendingChanges() async throws {
        try await startupRecovery()
    }
}
