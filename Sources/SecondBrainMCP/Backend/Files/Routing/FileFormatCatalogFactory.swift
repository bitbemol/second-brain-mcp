/// Composition root for concrete file-format operation bindings.
///
/// Every ``FileFormat`` case is exhaustively wired here. Adding a format cannot
/// compile until this factory defines its supported operations; formats may share
/// handlers, and each operation may bind independently.
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

        func definition(for format: FileFormat) -> FileFormatDefinition {
            switch format {
            case .markdown:
                storedFiles.definition(
                    format: format,
                    create: markdown.prepareCreate,
                    read: markdown.read,
                    update: markdown.prepareUpdate
                )
            case .canvas:
                storedFiles.definition(
                    format: format,
                    create: canvas.prepareCreate,
                    read: canvas.read,
                    update: canvas.prepareUpdate
                )
            case .har:
                storedFiles.definition(
                    format: format,
                    create: har.prepareCreate,
                    read: har.read
                )
            case .patch:
                storedFiles.definition(
                    format: format,
                    create: patch.prepareCreate,
                    read: patch.read
                )
            case .log:
                storedFiles.definition(
                    format: format,
                    create: log.prepareCreate,
                    read: log.read,
                    update: log.prepareUpdate
                )
            case .json:
                storedFiles.definition(
                    format: format,
                    create: json.prepareCreate,
                    read: json.read,
                    update: json.prepareUpdate
                )
            case .csv:
                storedFiles.definition(
                    format: format,
                    create: csv.prepareCreate,
                    read: csv.read,
                    update: csv.prepareUpdate
                )
            case .png:
                imageFiles.definition(
                    format,
                    create: image.preparePNG
                )
            case .gif:
                imageFiles.definition(
                    format,
                    create: image.prepareVideoGIF
                )
            case .jpeg, .webp, .heic, .tiff, .bmp:
                imageFiles.definition(format)
            case .pdf:
                FileFormatDefinition(
                    format: format,
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
            }
        }

        return FileFormatCatalog(
            definitions: FileFormat.allCases.map { definition(for: $0) }
        )
    }
}
