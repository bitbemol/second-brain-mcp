import MCP

/// Decodes MCP arguments into transport-neutral file requests.
enum FileToolRequestDecoder {
    /// Parameter validation failure returned directly to an MCP client.
    enum DecodingError: Error, CustomStringConvertible, Sendable {
        /// One or more tool arguments are missing or invalid.
        case invalid(String)

        /// Existing user-facing validation message.
        var description: String {
            switch self {
            case .invalid(let message): message
            }
        }
    }

    /// Extracts an unvalidated path for boundary-level rejection reporting.
    ///
    /// - Parameter params: Raw MCP tool-call parameters.
    /// - Returns: The supplied path string, when present.
    static func path(from params: CallTool.Parameters) -> String? {
        try? FileToolArguments(params).string(.path)
    }

    /// Decodes one recognized MCP file tool invocation.
    ///
    /// - Parameters:
    ///   - tool: Recognized compact tool name.
    ///   - params: Raw MCP tool-call parameters.
    /// - Returns: Transport-neutral request ready for the shared service port.
    /// - Throws: ``DecodingError`` when required arguments are invalid.
    static func decode(
        _ params: CallTool.Parameters,
        for tool: FileToolName
    ) throws -> FileToolRequest {
        let arguments = FileToolArguments(params)
        do {
            switch tool {
            case .create:
                return .create(try decodeCreate(arguments))
            case .read:
                return .read(try decodeRead(arguments))
            case .update:
                return .update(try decodeUpdate(arguments))
            case .delete:
                return .delete(try decodeDelete(arguments))
            }
        } catch let error as FileToolArguments.ValidationError {
            throw DecodingError.invalid(error.description)
        }
    }

    private static func decodeCreate(
        _ arguments: FileToolArguments
    ) throws -> CreateFileRequest {
        try arguments.requireOnly([
            .format, .path, .content, .source, .tags, .transform,
        ])
        let (format, path) = try identity(from: arguments)
        let transform: FileCreateTransform?
        if let value = try arguments.string(.transform) {
            guard let parsed = FileCreateTransform(rawValue: value) else {
                throw DecodingError.invalid("Invalid create transform: \(value)")
            }
            transform = parsed
        } else {
            transform = nil
        }
        return CreateFileRequest(
            format: format,
            path: path,
            content: try arguments.string(.content),
            source: try arguments.string(.source),
            tags: try arguments.stringArray(.tags) ?? [],
            transform: transform
        )
    }

    private static func decodeRead(
        _ arguments: FileToolArguments
    ) throws -> ReadFileRequest {
        try arguments.requireOnly([
            .format, .path, .tailLines, .startLine, .maxLines,
            .page, .pages, .pageRange,
        ])
        let (format, path) = try identity(from: arguments)
        return ReadFileRequest(
            format: format,
            path: path,
            options: ReadFileOptions(
                tailLines: try arguments.integer(.tailLines),
                startLine: try arguments.integer(.startLine),
                maxLines: try arguments.integer(.maxLines),
                page: try arguments.integer(.page),
                pages: try integerArray(.pages, from: arguments),
                pageRange: try arguments.string(.pageRange)
            )
        )
    }

    private static func decodeUpdate(
        _ arguments: FileToolArguments
    ) throws -> UpdateFileRequest {
        try arguments.requireOnly([
            .format, .path, .expectedRevision, .mode, .content, .replacements,
        ])
        let (format, path) = try identity(from: arguments)
        let modeString = try arguments.string(.mode) ?? "replace"
        guard let mode = FileUpdateMode(rawValue: modeString) else {
            throw DecodingError.invalid("Invalid update mode: \(modeString)")
        }
        var replacements: [TextReplacement] = []
        if let values = try arguments.array(.replacements) {
            for (index, value) in values.enumerated() {
                guard let object = value.objectValue,
                      let oldText = object[.oldText]?.stringValue,
                      let newText = object[.newText]?.stringValue else {
                    throw DecodingError.invalid(
                        "Replacement at index \(index) requires old_text and new_text"
                    )
                }
                replacements.append(TextReplacement(
                    oldText: oldText,
                    newText: newText
                ))
            }
        }
        return UpdateFileRequest(
            expectedRevision: try expectedRevision(from: arguments),
            format: format,
            path: path,
            content: try arguments.string(.content),
            mode: mode,
            replacements: replacements
        )
    }

    private static func decodeDelete(
        _ arguments: FileToolArguments
    ) throws -> DeleteFileRequest {
        try arguments.requireOnly([
            .format, .path, .expectedRevision,
        ])
        let (format, path) = try identity(from: arguments)
        return DeleteFileRequest(
            expectedRevision: try expectedRevision(from: arguments),
            format: format,
            path: path
        )
    }

    /// Decodes an optional array without accepting malformed elements.
    private static func integerArray(
        _ argument: FileToolArgument,
        from arguments: FileToolArguments
    ) throws -> [Int]? {
        guard let values = try arguments.array(argument) else { return nil }
        return try values.enumerated().map { index, value in
            guard let integer = value.intValue else {
                throw DecodingError.invalid(
                    "Invalid parameter '\(argument.rawValue)' at index \(index): expected integer"
                )
            }
            return integer
        }
    }

    /// Decodes the exact-byte revision required by update and delete.
    private static func expectedRevision(
        from arguments: FileToolArguments
    ) throws -> FileRevision {
        let value = try arguments.requiredString(.expectedRevision)
        guard let revision = FileRevision(rawValue: value) else {
            throw DecodingError.invalid(
                "Invalid expected_revision: expected sha256: followed by 64 lowercase hexadecimal digits"
            )
        }
        return revision
    }

    /// Decodes the concrete format and vault-relative path shared by every tool.
    private static func identity(
        from arguments: FileToolArguments
    ) throws -> (format: FileFormat, path: String) {
        let formatString = try arguments.requiredString(.format)
        guard let format = FileFormat(rawValue: formatString) else {
            throw DecodingError.invalid("Unsupported file format: \(formatString)")
        }
        let path = try arguments.requiredString(.path)
        return (format, path)
    }
}
