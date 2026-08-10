/// Composition root for concrete file-format operation bindings.
///
/// Every ``FileFormat`` case is exhaustively wired here. Adding a format cannot
/// compile until this factory defines its supported operations; formats may share
/// handlers, and each operation may bind independently.
enum FileFormatCatalogFactory {
    /// Constructs the immutable catalog used by the service and MCP discovery.
    ///
    /// - Parameters:
    ///   - store: Sole generic persistence actor.
    ///   - imageReader: Vault image read behavior.
    ///   - imageImporter: External-image preparation policy.
    ///   - videoImporter: External-video conversion policy.
    ///   - pdfReader: Read-only PDF behavior.
    /// - Returns: Fully wired format catalog.
    static func build(
        store: VaultCRUDStore,
        imageReader: ImageReader,
        imageImporter: ImageImporter,
        videoImporter: VideoImporter,
        pdfReader: PDFReader
    ) -> FileFormatCatalog {
        let markdown = MarkdownFileOperations()
        let canvas = CanvasFileOperations()
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

        // This exhaustive switch declares only each format's differences. The text and
        // image families supply their shared read, edit, and soft-delete bindings; cases
        // override creation, validation, reading, or update modes only when the format
        // contract requires different behavior.
        func definition(for format: FileFormat) -> FileFormatDefinition {
            switch format {
            case .markdown:
                storedFiles.definition(
                    format: format,
                    createContract: FileCreateContract(
                        input: .content,
                        transform: nil,
                        acceptsTags: true
                    ),
                    create: markdown.prepareCreate,
                    updateModes: Set(FileUpdateMode.allCases)
                )
            case .canvas:
                storedFiles.definition(
                    format: format,
                    create: canvas.prepareCreate,
                    validate: { data, _ in
                        try CanvasDocumentValidator.validate(jsonData: data)
                    },
                    updateModes: [.replace]
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
                    validate: { data, path in
                        _ = try PatchFileOperations.inspect(data: data, path: path)
                    }
                )
            case .log:
                storedFiles.definition(
                    format: format,
                    create: log.prepareCreate,
                    read: log.read,
                    updateModes: [.append]
                )
            case .json:
                storedFiles.definition(
                    format: format,
                    create: json.prepareCreate,
                    validate: JSONFileOperations.validate,
                    updateModes: [.replace, .patch]
                )
            case .csv:
                storedFiles.definition(
                    format: format,
                    create: csv.prepareCreate,
                    validate: CSVFileOperations.validate,
                    updateModes: Set(FileUpdateMode.allCases),
                    append: CSVFileOperations.appendingRows
                )
            case .png:
                imageFiles.definition(
                    format,
                    contract: FileCreateContract(
                        input: .source,
                        transform: nil,
                        acceptsTags: false
                    ),
                    create: image.preparePNG
                )
            case .gif:
                imageFiles.definition(
                    format,
                    contract: FileCreateContract(
                        input: .source,
                        transform: .videoToGIF,
                        acceptsTags: false
                    ),
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
