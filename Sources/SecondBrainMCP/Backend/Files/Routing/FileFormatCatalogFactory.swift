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
        let image = ImageFileOperations(
            imageReader: imageReader,
            imageImporter: imageImporter,
            videoImporter: videoImporter
        )
        let pdf = PDFFileOperations(reader: pdfReader)

        let softDelete = DeleteOperationBinding(
            id: .softDelete,
            allowedAreas: [.notes],
            execute: { _, _ in }
        )
        let storedFiles = StoredTextFileOperationFamily(store: store, delete: softDelete)
        let imageFiles = ImageFileOperationFamily(read: image.read, delete: softDelete)

        let definitions: [FileFormatDefinition] = [
            storedFiles.definition(
                format: .markdown,
                handler: .markdown,
                create: markdown.prepareCreate,
                read: markdown.read,
                update: markdown.prepareUpdate
            ),
            storedFiles.definition(
                format: .canvas,
                handler: .canvas,
                create: canvas.prepareCreate,
                read: canvas.read,
                update: canvas.prepareUpdate
            ),
            storedFiles.definition(
                format: .har,
                handler: .har,
                create: har.prepareCreate,
                read: har.read
            ),
            storedFiles.definition(
                format: .patch,
                handler: .patch,
                create: patch.prepareCreate,
                read: patch.read
            ),
            storedFiles.definition(
                format: .log,
                handler: .log,
                create: log.prepareCreate,
                read: log.read,
                update: log.prepareUpdate
            ),
            imageFiles.definition(
                .png,
                createHandler: .image,
                create: image.preparePNG
            ),
            imageFiles.definition(.jpeg),
            imageFiles.definition(
                .gif,
                createHandler: .videoToGIF,
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
                        id: .pdf,
                        allowedAreas: [.references],
                        execute: pdf.read
                    ),
                    update: nil,
                    delete: softDelete
                )
            )
        ]
        return FileFormatCatalog(definitions: definitions)
    }
}
