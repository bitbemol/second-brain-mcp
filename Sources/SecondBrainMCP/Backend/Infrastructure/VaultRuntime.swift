/// Fully initialized backend dependencies for one vault process.
///
/// This is the backend composition root. It owns construction and startup order,
/// while the frontend consumes only the routed file service and shared,
/// transport-neutral capability and rejection boundaries.
struct VaultRuntime: Sendable {
    /// Routed generic file service.
    let files: any FileCRUDService
    /// Immutable capability projection shared with MCP discovery.
    let capabilities: FileCapabilities
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
            migrateLegacyData: !readOnly
        )

        let git = GitRepository(repoPath: vaultPath)
        if !readOnly {
            try await git.ensureRepository()
        }

        let audit = AuditLogger(dataDirectory: dataDirectory)
        let rejections = AuditRejectionReporter(audit: audit)
        let store = VaultCRUDStore(vaultPath: vaultPath)
        let mutations = VaultMutationExecutor(git: git, audit: audit)
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
            audit: audit,
            readOnly: readOnly
        )
        return VaultRuntime(
            files: files,
            capabilities: catalog.capabilities(),
            rejections: rejections
        )
    }
}
