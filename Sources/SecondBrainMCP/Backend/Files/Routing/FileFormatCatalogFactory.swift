/// Composition root for concrete file-format operation bindings.
///
/// Adding a format means registering a ``FileFormatDefinition`` here. Multiple
/// definitions may share the same handler function, and each operation may bind
/// independently.
enum FileFormatCatalogFactory {
    /// Constructs the immutable catalog used by the service and MCP discovery.
    ///
    /// - Parameters:
    ///   - vaultPath: Canonical vault root used by handlers that inspect links.
    ///   - store: Sole generic persistence actor.
    ///   - imageReader: Vault image read behavior.
    ///   - imageImporter: External-image preparation policy.
    ///   - videoImporter: External-video conversion policy.
    ///   - pdfReader: Read-only PDF behavior.
    /// - Returns: Fully wired format catalog.
    static func build(
        vaultPath: String,
        store: VaultCRUDStore,
        imageReader: ImageReader,
        imageImporter: ImageImporter,
        videoImporter: VideoImporter,
        pdfReader: PDFReader
    ) -> FileFormatCatalog {
        let markdown = MarkdownFileOperations()
        let canvas = CanvasFileOperations(vaultPath: vaultPath)
        let har = HARFileOperations()
        let patch = PatchFileOperations()
        let log = LogFileOperations()
        let json = JSONFileOperations()
        let csv = CSVFileOperations()
        let image = ImageFileOperations(
            imageReader: imageReader,
            imageImporter: imageImporter,
            videoImporter: videoImporter
        )
        let pdf = PDFFileOperations(reader: pdfReader)

        let softDelete = DeleteOperationBinding(
            allowedAreas: [.notes],
            execute: { _, _ in }
        )
        let storedFiles = StoredTextFileOperationFamily(store: store, delete: softDelete)
        let imageFiles = ImageFileOperationFamily(read: image.read, delete: softDelete)

        let definitions: [FileFormatDefinition] = [
            storedFiles.definition(
                format: .markdown,
                create: markdown.prepareCreate,
                read: markdown.read,
                update: markdown.prepareUpdate
            ),
            storedFiles.definition(
                format: .canvas,
                create: canvas.prepareCreate,
                read: canvas.read,
                update: canvas.prepareUpdate
            ),
            storedFiles.definition(
                format: .har,
                create: har.prepareCreate,
                read: har.read
            ),
            storedFiles.definition(
                format: .patch,
                create: patch.prepareCreate,
                read: patch.read
            ),
            storedFiles.definition(
                format: .log,
                create: log.prepareCreate,
                read: log.read,
                update: log.prepareUpdate
            ),
            storedFiles.definition(
                format: .json,
                create: json.prepareCreate,
                read: json.read,
                update: json.prepareUpdate
            ),
            storedFiles.definition(
                format: .csv,
                create: csv.prepareCreate,
                read: csv.read,
                update: csv.prepareUpdate
            ),
            imageFiles.definition(
                .png,
                create: image.preparePNG
            ),
            imageFiles.definition(.jpeg),
            imageFiles.definition(
                .gif,
                create: image.prepareVideoGIF
            ),
            imageFiles.definition(.webp),
            imageFiles.definition(.heic),
            imageFiles.definition(.tiff),
            imageFiles.definition(.bmp),
            FileFormatDefinition(
                format: .pdf,
                operations: FormatOperations(
                    create: nil,
                    read: ReadOperationBinding(
                        allowedAreas: [.references],
                        execute: pdf.read
                    ),
                    update: nil,
                    delete: nil
                )
            )
        ]
        return FileFormatCatalog(definitions: definitions)
    }
}
