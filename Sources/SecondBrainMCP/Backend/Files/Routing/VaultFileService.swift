import Foundation

/// Routes generic file CRUD through format handlers, atomic storage, one global
/// vault access boundary, and the awaited versioning chain.
actor VaultFileService: FileCRUDService {
    private let catalog: FileFormatCatalog
    private let vaultPath: String
    private let store: VaultCRUDStore
    private let mutations: VaultMutationExecutor
    private let access: any VaultAccessCoordinating
    private let metadataReader: FileMetadataReader
    private let readOnly: Bool

    init(
        vaultPath: String,
        catalog: FileFormatCatalog,
        store: VaultCRUDStore,
        mutations: VaultMutationExecutor,
        access: any VaultAccessCoordinating,
        metadataReader: FileMetadataReader = FileMetadataReader(pdfReader: PDFReader()),
        readOnly: Bool = false
    ) {
        self.vaultPath = vaultPath
        self.catalog = catalog
        self.store = store
        self.mutations = mutations
        self.access = access
        self.metadataReader = metadataReader
        self.readOnly = readOnly
    }

    func create(_ request: CreateFileRequest) async throws -> FileOperationOutput {
        try requireMutationPermission()
        return try await access.withMutation {
            let target = try self.resolveWritableTarget(
                path: request.path,
                format: request.format
            )
            try FileMutationResourcePreflight.validate(request)
            let binding = try self.catalog.createBinding(
                for: request.format,
                in: target.area
            )
            try CreateFileContractValidator.validate(request, against: binding.contract)
            try await self.store.requireAbsent(target)
            let prepared = try await binding.execute(request, target)
            try SensitiveContentPolicy.validate(
                prepared.data,
                format: target.format,
                path: target.relativePath
            )
            try await self.store.requireAbsent(target)
            let revision = FileSnapshot(
                data: prepared.data,
                modifiedDate: nil
            ).revision
            let output = prepared.output.withMetadata(FileOperationMetadata(
                path: target.relativePath,
                area: target.area,
                revision: revision
            ))
            return try await self.mutations.execute(PreparedVaultMutation(
                requiresSnapshot: true,
                perform: {
                    _ = try await self.store.create(
                        target: target,
                        data: prepared.data
                    )
                    return output
                }
            ))
        }
    }

    func read(_ request: ReadFileRequest) async throws -> FileOperationOutput {
        try await access.withRead {
            try ReadFileOptionsValidator.validate(request)
            let target = try ReadableFileTarget.resolve(
                path: request.path,
                format: request.format,
                vaultPath: self.vaultPath
            )
            let binding = try self.catalog.readBinding(
                for: request.format,
                in: target.area
            )
            let snapshot = try await self.store.snapshot(target)
            if let expectedRevision = request.options.expectedRevision,
               snapshot.revision != expectedRevision {
                throw FileRoutingError.revisionConflict(target.relativePath)
            }
            let output: FileOperationOutput
            if request.options.view == .metadata {
                output = try await self.metadataReader.read(
                    request,
                    target: target,
                    snapshot: snapshot
                )
            } else {
                output = try await binding.execute(request, target, snapshot)
            }
            return output.withMetadata(FileOperationMetadata(
                path: target.relativePath,
                area: target.area,
                revision: target.area == .notes ? snapshot.revision : nil
            ))
        }
    }

    func update(_ request: UpdateFileRequest) async throws -> FileOperationOutput {
        try requireMutationPermission()
        return try await access.withMutation {
            let target = try self.resolveWritableTarget(
                path: request.path,
                format: request.format
            )
            try FileMutationResourcePreflight.validate(request)
            let binding = try self.catalog.updateBinding(
                for: request.format,
                in: target.area
            )
            let snapshot = try await self.store.snapshot(target.readable)
            guard snapshot.revision == request.expectedRevision else {
                throw FileRoutingError.revisionConflict(target.relativePath)
            }
            let prepared = try await binding.execute(request, target, snapshot)
            try SensitiveContentPolicy.validate(
                prepared.data,
                format: target.format,
                path: target.relativePath
            )
            let noChanges = prepared.data == snapshot.data
            let revision = noChanges
                ? snapshot.revision
                : FileSnapshot(data: prepared.data, modifiedDate: nil).revision
            let output = (noChanges
                ? FileOperationOutput.text("No changes: \(target.relativePath)")
                : prepared.output
            ).withMetadata(FileOperationMetadata(
                path: target.relativePath,
                area: target.area,
                revision: revision
            ))
            return try await self.mutations.execute(PreparedVaultMutation(
                requiresSnapshot: !noChanges,
                perform: {
                    guard !noChanges else { return output }
                    do {
                        _ = try await self.store.replace(
                            target: target,
                            data: prepared.data,
                            expectedRevision: request.expectedRevision
                        )
                    } catch VaultCRUDStore.StoreError.changedSinceRead {
                        throw FileRoutingError.revisionConflict(target.relativePath)
                    }
                    return output
                }
            ))
        }
    }

    func delete(_ request: DeleteFileRequest) async throws -> FileOperationOutput {
        try requireMutationPermission()
        return try await access.withMutation {
            let target = try self.resolveWritableTarget(
                path: request.path,
                format: request.format
            )
            let binding = try self.catalog.deleteBinding(
                for: request.format,
                in: target.area
            )
            let snapshot = try await self.store.snapshot(target.readable)
            guard snapshot.revision == request.expectedRevision else {
                throw FileRoutingError.revisionConflict(target.relativePath)
            }
            try await binding.execute(request, target)
            return try await self.mutations.execute(PreparedVaultMutation(
                requiresSnapshot: true,
                perform: {
                    let deletion: (trashPath: String, deletedRevision: FileRevision)
                    do {
                        deletion = try await self.store.softDelete(
                            target: target,
                            expectedRevision: request.expectedRevision
                        )
                    } catch VaultCRUDStore.StoreError.changedSinceRead {
                        throw FileRoutingError.revisionConflict(target.relativePath)
                    }
                    return FileOperationOutput.text(
                        "Deleted \(target.relativePath) → \(deletion.trashPath)"
                    ).withMetadata(FileOperationMetadata(
                        path: target.relativePath,
                        area: target.area,
                        revision: nil
                    ))
                }
            ))
        }
    }

    private nonisolated func resolveWritableTarget(
        path: String,
        format: FileFormat
    ) throws -> WritableFileTarget {
        try WritableFileTarget.resolve(
            path: path,
            format: format,
            vaultPath: vaultPath
        )
    }

    private func requireMutationPermission() throws {
        guard !readOnly else { throw FileRoutingError.readOnly }
    }
}

/// Validates format-specific read selectors before any snapshot is interpreted.
private enum ReadFileOptionsValidator {
    static func validate(_ request: ReadFileRequest) throws {
        let options = request.options
        if options.view == .metadata {
            try validateMetadataSelectors(request)
            return
        }
        switch request.format {
        case .markdown, .canvas, .har, .patch, .json, .csv:
            try rejectLogSelectors(options)
            try rejectPDFSelectors(options)
            try validateTextSelectors(options)
        case .log:
            try rejectPDFSelectors(options)
            if options.byteOffset != nil || options.maxBytes != nil {
                try rejectLogSelectors(options)
                try validateTextSelectors(options)
            } else {
                try validateLogSelectors(options)
            }
        case .pdf:
            try rejectTextSelectors(options)
            try rejectLogSelectors(options)
            guard options.expectedRevision == nil else {
                throw invalid("expected_revision is available only for note text reads")
            }
        case .png, .gif, .jpeg, .webp, .heic, .tiff, .bmp:
            try rejectTextSelectors(options)
            try rejectLogSelectors(options)
            try rejectPDFSelectors(options)
            guard options.expectedRevision == nil else {
                throw invalid("expected_revision is available only for note text reads")
            }
        }
    }

    private static func validateMetadataSelectors(
        _ request: ReadFileRequest
    ) throws {
        guard request.format == .markdown || request.format == .pdf else {
            throw invalid("metadata view is supported only for markdown and pdf")
        }
        let options = request.options
        guard options.tailLines == nil,
              options.startLine == nil,
              options.maxLines == nil,
              options.page == nil,
              options.pages == nil,
              options.pageRange == nil,
              options.byteOffset == nil,
              options.maxBytes == nil,
              options.expectedRevision == nil else {
            throw invalid("metadata view cannot be combined with content selectors or expected_revision")
        }
    }

    private static func validateTextSelectors(
        _ options: ReadFileOptions
    ) throws {
        let offset = options.byteOffset ?? 0
        guard offset >= 0 else {
            throw invalid("byte_offset must be zero or greater")
        }
        if offset > 0, options.expectedRevision == nil {
            throw invalid(
                "byte_offset greater than zero requires expected_revision from the preceding chunk"
            )
        }
        let maximum = options.maxBytes
            ?? FileReadRequestLimits.defaultTextChunkBytes
        guard maximum >= FileReadRequestLimits.minimumTextChunkBytes,
              maximum <= FileReadRequestLimits.maximumTextChunkBytes else {
            throw invalid(
                "max_bytes must be between "
                    + "\(FileReadRequestLimits.minimumTextChunkBytes) and "
                    + "\(FileReadRequestLimits.maximumTextChunkBytes)"
            )
        }
    }

    private static func validateLogSelectors(
        _ options: ReadFileOptions
    ) throws {
        guard !(options.tailLines != nil && options.startLine != nil) else {
            throw invalid("tail_lines and start_line are mutually exclusive")
        }
        guard options.maxLines == nil || options.startLine != nil else {
            throw invalid("max_lines requires start_line")
        }
        for (name, value) in [
            ("tail_lines", options.tailLines),
            ("start_line", options.startLine),
            ("max_lines", options.maxLines),
        ] {
            guard let value else { continue }
            guard value > 0 else {
                throw invalid("\(name) must be greater than zero")
            }
            if name != "start_line", value > 5_000 {
                throw invalid("\(name) must not exceed 5000")
            }
        }
    }

    private static func rejectTextSelectors(
        _ options: ReadFileOptions
    ) throws {
        guard options.byteOffset == nil, options.maxBytes == nil else {
            throw invalid("byte_offset and max_bytes are available only for UTF-8 text reads")
        }
    }

    private static func rejectLogSelectors(
        _ options: ReadFileOptions
    ) throws {
        guard options.tailLines == nil,
              options.startLine == nil,
              options.maxLines == nil else {
            throw invalid("log line selectors cannot be combined with this read mode")
        }
    }

    private static func rejectPDFSelectors(
        _ options: ReadFileOptions
    ) throws {
        guard options.page == nil,
              options.pages == nil,
              options.pageRange == nil else {
            throw invalid("PDF page selectors cannot be combined with this read mode")
        }
    }

    private static func invalid(_ message: String) -> FileRoutingError {
        .invalidReadOptions(message)
    }
}
