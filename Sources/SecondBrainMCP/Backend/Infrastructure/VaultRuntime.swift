/// Fully initialized backend dependencies for one vault process.
///
/// This is the backend composition root. It owns construction and startup order,
/// while the frontend consumes only the routed file service and shared,
/// transport-neutral capability and rejection boundaries.
struct VaultRuntime: Sendable {
    /// Routed generic file service.
    let files: any FileCRUDService
    /// Bounded read-only search service.
    let search: any VaultSearchService
    /// Immutable capability projection shared with MCP discovery.
    let capabilities: FileCapabilities
    /// Searchable formats derived from the file capability projection.
    let searchCapabilities: SearchCapabilities
    /// Boundary used by the frontend to report requests rejected before routing.
    let rejections: any FileRequestRejectionReporting

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
        let dataDirectory = try VaultDataDirectory.prepare(
            vaultPath: vaultPath,
            // Writable startup performs migration below while holding the same
            // cross-process lock as Git bootstrap. Read-only startup never migrates.
            migrateLegacyData: false
        )

        let processMutationLock = POSIXAdvisoryFileLock(
            url: dataDirectory.lockDirectoryURL
                .appendingPathComponent("vault-mutations.lock")
        )
        let mutationReceipts = MutationReceiptStore(dataDirectory: dataDirectory)
        let git = GitRepository(repoPath: vaultPath)
        if !readOnly {
            // Legacy migration, startup snapshots, and CRUD commits share one
            // repository-wide lock across every MCP process using this vault.
            try await processMutationLock.withLock(.exclusive) {
                // A dirty vault may belong to a transaction awaiting commit-only
                // recovery. Do not let startup migration or snapshotting obscure it.
                let bootstrapIsSafe = try mutationReceipts
                    .clearCompletedActiveTransactionForBootstrap()
                if bootstrapIsSafe {
                    try dataDirectory.migrateLegacyData(from: vaultPath)
                    try await git.ensureRepository()
                }
            }
        }

        let audit = AuditLogger(
            dataDirectory: dataDirectory,
            coordinateAcrossProcesses: true
        )
        let rejections = AuditRejectionReporter(audit: audit)
        let store = VaultCRUDStore(vaultPath: vaultPath)
        let mutations = VaultMutationExecutor(
            git: git,
            audit: audit,
            processMutationLock: processMutationLock,
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
        let catalog = FileFormatCatalogFactory.build(
            vaultPath: vaultPath,
            store: store,
            imageReader: imageReader,
            imageImporter: imageImporter,
            videoImporter: VideoImporter(
                sourceValidator: externalSources,
                encoder: AVFoundationVideoEncoder()
            ),
            pdfReader: PDFReader()
        )
        let files = VaultFileService(
            vaultPath: vaultPath,
            catalog: catalog,
            store: store,
            mutations: mutations,
            operations: operations,
            audit: audit,
            readOnly: readOnly
        )
        let capabilities = catalog.capabilities()
        let searchCapabilities = SearchCapabilities(
            fileCapabilities: capabilities
        )
        let search = VaultSearchEngine(
            vaultPath: vaultPath,
            capabilities: searchCapabilities,
            store: store,
            operations: operations,
            processSearchLock: POSIXAdvisoryFileLock(
                url: dataDirectory.lockDirectoryURL
                    .appendingPathComponent("vault-search.lock")
            )
        )
        return VaultRuntime(
            files: files,
            search: search,
            capabilities: capabilities,
            searchCapabilities: searchCapabilities,
            rejections: rejections
        )
    }
}
