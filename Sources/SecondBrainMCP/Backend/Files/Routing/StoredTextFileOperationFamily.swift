import Foundation

/// Reusable CRUD assembly for UTF-8 formats stored as ordinary vault files.
///
/// The family owns shared ingress, exact-content reads, text editing, snapshot
/// loading, notes-area policy, and soft deletion. Catalog entries provide only
/// the format semantics that differ: validation, special reads, and update modes.
struct StoredTextFileOperationFamily: Sendable {
    private let delete: DeleteOperationBinding
    private let ingress = TextFileIngress()

    init(delete: DeleteOperationBinding) {
        self.delete = delete
    }

    /// Registers one text format and its complete public behavior.
    ///
    /// Callers provide only policy that differs by format. Creation is explicit because
    /// untrusted input may require validation or sanitization before persistence. Reads
    /// default to exact UTF-8 content but may override that behavior for safety or bounded
    /// output. Updates reuse one edit engine and are enabled only through declared modes;
    /// validators run against the final bytes. Deletion is not a parameter because every
    /// writable text format uses the same recoverable soft-delete binding.
    ///
    /// This split is based on format-specific behavior, not whether an operation mutates:
    /// delete is destructive but generic, while HAR and log reads are safe but specialized.
    func definition(
        format: FileFormat,
        createContract: FileCreateContract = .content,
        create: @escaping StoredTextCreateResolver,
        validate: StoredTextValidator? = nil,
        read: StoredReadResolver? = nil,
        updateModes: Set<FileUpdateMode> = [],
        append: @escaping StoredTextAppender = TextFileSupport.appending
    ) -> FileFormatDefinition {
        FileFormatDefinition(
            format: format,
            operations: FormatOperations(
                create: storedCreate(contract: createContract, resolve: create),
                read: storedRead(validate: validate, resolve: read),
                update: updateModes.isEmpty ? nil : storedUpdate(
                    format: format,
                    supportedModes: updateModes,
                    validate: validate,
                    append: append
                ),
                delete: delete
            )
        )
    }

    private func storedCreate(
        contract: FileCreateContract,
        resolve: @escaping StoredTextCreateResolver
    ) -> CreateOperationBinding {
        CreateOperationBinding(
            allowedAreas: [.notes],
            contract: contract
        ) { request, target in
            let input = try ingress.prepare(request, for: target)
            return try resolve(input, target)
        }
    }

    private func storedRead(
        validate: StoredTextValidator?,
        resolve: StoredReadResolver?
    ) -> ReadOperationBinding {
        ReadOperationBinding(allowedAreas: [.notes]) { request, target, snapshot in
            if let resolve {
                return try resolve(request, target, snapshot)
            }
            try validate?(snapshot.data, target.relativePath)
            return .text(
                try TextFileSupport.stringPreservingByteOrderMark(from: snapshot.data)
            )
        }
    }

    private func storedUpdate(
        format: FileFormat,
        supportedModes: Set<FileUpdateMode>,
        validate: StoredTextValidator?,
        append: @escaping StoredTextAppender
    ) -> UpdateOperationBinding {
        UpdateOperationBinding(
            allowedAreas: [.notes],
            supportedModes: supportedModes
        ) { request, target, snapshot in
            guard supportedModes.contains(request.mode) else {
                throw FileRoutingError.operationNotSupported(
                    format: format,
                    operation: .update,
                    area: .notes
                )
            }

            let existing = try TextFileSupport.stringPreservingByteOrderMark(
                from: snapshot.data
            )
            let updated: String
            switch request.mode {
            case .replace:
                guard let content = request.content else {
                    throw TextFileSupport.TextError.missingContent
                }
                updated = content
            case .append:
                guard let content = request.content else {
                    throw TextFileSupport.TextError.missingContent
                }
                updated = append(content, existing)
            case .patch:
                updated = try TextFileSupport.apply(
                    request.replacements,
                    to: existing
                )
            }

            let data = Data(updated.utf8)
            try validate?(data, target.relativePath)
            return PreparedFileWrite(
                data: data,
                output: .text(
                    "Updated \(target.relativePath) (\(request.mode.rawValue))"
                )
            )
        }
    }
}
