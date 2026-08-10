import Foundation

/// Fully initialized backend dependencies for one vault process.
///
/// This is the backend composition root. It owns construction and startup order,
/// while the frontend consumes only the routed file service and shared,
/// transport-neutral capability and rejection boundaries.
struct VaultRuntime: Sendable {
    /// Routed generic file service.
    let files: any FileCRUDService
    /// Atomic recursive notes-directory moves.
    let directories: any DirectoryMoveService
    /// Bounded read-only search service.
    let search: any VaultSearchService
    /// Immutable capability projection shared with MCP discovery.
    let capabilities: FileCapabilities

    /// Prepares permitted process state and constructs the backend graph.
    ///
    /// - Parameters:
    ///   - vaultPath: Canonical absolute vault root.
    ///   - readOnly: Whether bootstrap and routed operations must avoid vault mutations.
    /// - Returns: A ready-to-serve backend runtime.
    static func bootstrap(
        vaultPath: String,
        readOnly: Bool = false
    ) async throws -> VaultRuntime {
        let dataDirectory = try VaultDataDirectory.prepare(vaultPath: vaultPath)

        let mutationReceipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let versioning = try GitRepository(
            repositoryURL: URL(fileURLWithPath: vaultPath, isDirectory: true),
            lockURL: dataDirectory.lockDirectoryURL
                .appendingPathComponent("vault-versioning.lock")
        )
        if !readOnly {
            try await versioning.recordSnapshot()
        }
        let store = VaultCRUDStore(vaultPath: vaultPath)
        let mutations = VaultMutationExecutor(
            versioning: versioning,
            receipts: mutationReceipts
        )
        let operations = VaultOperationCoordinator(
            lockDirectoryURL: dataDirectory.lockDirectoryURL
        )
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
            vaultPath: vaultPath,
            store: store,
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
            operations: operations,
            readOnly: readOnly
        )
        let directories = VaultDirectoryMoveService(
            vaultPath: vaultPath,
            versioning: versioning,
            receipts: mutationReceipts,
            operations: operations,
            readOnly: readOnly
        )
        let capabilities = catalog.capabilities()
        let searchSource = SearchCorpusBuilder(
            vaultPath: vaultPath,
            capabilities: capabilities,
            store: store,
            operations: operations,
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
            capabilities: capabilities
        )
    }
}
