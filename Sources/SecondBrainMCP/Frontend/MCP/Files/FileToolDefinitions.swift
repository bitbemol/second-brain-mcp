import Foundation
import MCP

/// Builds the compact, capability-derived MCP file tool definitions.
enum FileToolDefinitions {
    /// Builds JSON-schema tool definitions from the shared capability manifest.
    ///
    /// The schema format enums are derived from `capabilities`; adding a format never
    /// requires duplicating its name in this frontend adapter.
    ///
    /// - Parameters:
    ///   - capabilities: Effective format, operation, and area support.
    ///   - readOnly: Whether mutating tools must be omitted.
    /// - Returns: The effective generic file tools.
    static func build(capabilities: FileCapabilities, readOnly: Bool) -> [Tool] {
        FileToolName.allCases.compactMap { tool in
            guard !readOnly || !tool.operation.isMutation else { return nil }
            return definition(for: tool, capabilities: capabilities)
        }
    }

    /// Builds the operation-specific schema for one registered tool name.
    private static func definition(
        for tool: FileToolName,
        capabilities: FileCapabilities
    ) -> Tool {
        switch tool {
        case .create:
            Tool(
                name: tool.rawValue,
                description: "Create a supported concrete file under notes/. Creation is atomic and requires the destination to be absent. The format field describes whether each registered type accepts content or source and whether it requires a transform. The declared format, destination extension, and actual content must agree. Specialized handlers validate or transform input before the shared persistence, revision, and Git pipeline.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .create),
                    formatDescription: createContractDescription(capabilities),
                    pathDescription: "Destination under notes/ with an extension matching format",
                    additionalProperties: [
                        .content: .object([
                            "type": .string("string"),
                            "description": .string(
                                inputDescription(.content, capabilities: capabilities)
                            )
                        ]),
                        .source: .object([
                            "type": .string("string"),
                            "maxLength": .int(
                                FileMutationRequestLimits.maximumSourcePathBytes
                            ),
                            "description": .string(
                                inputDescription(.source, capabilities: capabilities)
                            )
                        ]),
                        .tags: .object([
                            "type": .string("array"),
                            "maxItems": .int(
                                FileMutationRequestLimits.maximumTagCount
                            ),
                            "items": .object([
                                "type": .string("string"),
                                "maxLength": .int(
                                    FileMutationRequestLimits.maximumTagBytes
                                )
                            ]),
                            "description": .string(
                                tagDescription(capabilities)
                            )
                        ]),
                        .transform: .object([
                            "type": .string("string"),
                            "enum": .array(
                                FileCreateTransform.allCases.map {
                                    .string($0.rawValue)
                                }
                            ),
                            "description": .string(
                                transformDescription(capabilities)
                            )
                        ])
                    ]
                ),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: true
                ),
                outputSchema: outputSchema(
                    required: [.path, .area, .revision]
                )
            )
        case .read:
            Tool(
                name: tool.rawValue,
                description: "Read one known file after list_files, search_vault, or query_links. Use view=metadata for content-free Markdown title/tags/word count/links or bounded PDF title/author/page labels/outline; do not combine metadata with content selectors. The default content view returns bounded UTF-8 chunks, log lines, images, or physical PDF pages. For a Canvas result from search_vault, pass both canvas_node_id and canvas_field to read only that decoded field instead of paging through the raw JSON; repeat both selectors on every continuation. Continue text with text_window.next_byte_offset and the same revision as expected_revision. Reads under notes/ return the exact revision required before update_file, delete_file, or file-form move_path.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .read),
                    formatDescription: "Concrete file format; must match the path extension and actual content",
                    pathDescription: "Vault-relative path under notes/ or references/",
                    additionalProperties: [
                        .view: .object([
                            "type": .string("string"),
                            "enum": .array(ReadFileView.allCases.map { .string($0.rawValue) }),
                            "default": .string(ReadFileView.content.rawValue),
                            "description": .string("content returns file data; metadata returns no file content and is supported for markdown and pdf"),
                        ]),
                        .canvasNodeID: .object([
                            "type": .string("string"),
                            "description": .string("For Canvas content, the exact node ID returned by search_vault. Requires canvas_field and must be repeated for every continuation."),
                        ]),
                        .canvasField: .object([
                            "type": .string("string"),
                            "enum": .array(CanvasReadField.allCases.map { .string($0.rawValue) }),
                            "description": .string("For Canvas content, the exact field returned by search_vault. Requires canvas_node_id; reads the decoded field as bounded UTF-8."),
                        ]),
                        .tailLines: .object([
                            "type": .string("integer"), "minimum": .int(1), "maximum": .int(5_000),
                            "description": .string("For logs, return the last N lines")
                        ]),
                        .startLine: .object([
                            "type": .string("integer"), "minimum": .int(1),
                            "description": .string("For logs, first 1-indexed line to return")
                        ]),
                        .maxLines: .object([
                            "type": .string("integer"), "minimum": .int(1), "maximum": .int(5_000),
                            "description": .string("For logs with start_line, maximum lines")
                        ]),
                        .page: .object([
                            "type": .string("integer"), "minimum": .int(1),
                            "description": .string("For PDFs, one physical 1-indexed page")
                        ]),
                        .pages: .object([
                            "type": .string("array"),
                            "minItems": .int(1),
                            "maxItems": .int(FileReadRequestLimits.maximumPDFPagesPerRead),
                            "uniqueItems": .bool(true),
                            "items": .object([
                                "type": .string("integer"),
                                "minimum": .int(1),
                            ]),
                            "description": .string("For PDFs, ordered physical pages; mutually exclusive with page and page_range"),
                        ]),
                        .pageRange: .object([
                            "type": .string("string"),
                            "minLength": .int(1),
                            "maxLength": .int(FileReadRequestLimits.maximumPDFPageRangeBytes),
                            "pattern": .string("^\\d+-\\d+$"),
                            "description": .string("For PDFs, an inclusive physical range such as 7-10; mutually exclusive with page and pages"),
                        ]),
                        .byteOffset: .object([
                            "type": .string("integer"),
                            "minimum": .int(0),
                            "description": .string("For UTF-8 text, zero-based byte offset. Values above zero require expected_revision from the preceding chunk."),
                        ]),
                        .maxBytes: .object([
                            "type": .string("integer"),
                            "minimum": .int(FileReadRequestLimits.minimumTextChunkBytes),
                            "maximum": .int(FileReadRequestLimits.maximumTextChunkBytes),
                            "default": .int(FileReadRequestLimits.defaultTextChunkBytes),
                            "description": .string("Maximum UTF-8 bytes in one text chunk; chunk boundaries never split a scalar."),
                        ]),
                        .expectedRevision: expectedRevisionSchema,
                    ]
                ),
                annotations: .init(
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                ),
                outputSchema: outputSchema(
                    required: [.path, .area],
                    includesRevision: true,
                    includesReadFields: true
                )
            )
        case .update:
            Tool(
                name: tool.rawValue,
                description: "Update a supported file under notes/. The mode field describes the modes registered for each format. expected_revision must be the opaque revision returned by the read on which this edit is based; a conflict requires reading and reconsidering the file before retrying. The shared edit engine validates the final format-specific content before the persistence, revision, and Git pipeline. No-op results return the unchanged revision without creating a commit.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .update),
                    formatDescription: "Concrete file format",
                    pathDescription: "Existing file under notes/",
                    additionalProperties: [
                        .expectedRevision: expectedRevisionSchema,
                        .mode: .object([
                            "type": .string("string"),
                            "enum": .array(
                                FileUpdateMode.allCases.map {
                                    .string($0.rawValue)
                                }
                            ),
                            "description": .string(updateModeDescription(capabilities))
                        ]),
                        .content: .object(["type": .string("string"), "description": .string("Required for replace or append")]),
                        .replacements: .object([
                            "type": .string("array"),
                            "maxItems": .int(FileMutationRequestLimits.maximumReplacements),
                            "description": .string(
                                patchDescription(capabilities)
                            ),
                            "items": .object([
                                "type": .string("object"),
                                "properties": argumentObject([
                                    .oldText: .object([
                                        "type": .string("string"),
                                        "minLength": .int(1),
                                    ]),
                                    .newText: .object(["type": .string("string")])
                                ]),
                                "required": requiredArguments([.oldText, .newText]),
                                "additionalProperties": .bool(false),
                            ])
                        ])
                    ],
                    additionalRequired: [.expectedRevision, .mode],
                    alternatives: updateModeVariants
                ),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: false,
                    openWorldHint: false
                ),
                outputSchema: outputSchema(
                    required: [.path, .area, .revision]
                )
            )
        case .delete:
            Tool(
                name: tool.rawValue,
                description: "Soft-delete a supported file under notes/ by moving it to .trash/. expected_revision must be the opaque revision returned by the read that authorized deletion; a conflict requires a fresh read. The declared format and extension must agree. References are structurally read-only. Git auto-commits the deletion.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .delete),
                    formatDescription: "Concrete file format",
                    pathDescription: "Existing file under notes/",
                    additionalProperties: [
                        .expectedRevision: expectedRevisionSchema,
                    ],
                    additionalRequired: [.expectedRevision]
                ),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: false,
                    openWorldHint: false
                ),
                outputSchema: outputSchema(
                    required: [.path, .area]
                )
            )
        }
    }

    private static func inputDescription(
        _ input: FileCreateContract.Input,
        capabilities: FileCapabilities
    ) -> String {
        let formats = capabilities.formats.compactMap { capability -> String? in
            guard capability.createContract?.input.rawValue == input.rawValue else {
                return nil
            }
            return capability.format.rawValue
        }
        return "Required \(input.rawValue) input for: "
            + formats.joined(separator: ", ")
    }

    private static func tagDescription(
        _ capabilities: FileCapabilities
    ) -> String {
        let formats = capabilities.formats.compactMap { capability in
            capability.createContract?.acceptsTags == true
                ? capability.format.rawValue
                : nil
        }
        return "Optional tags accepted by: " + formats.joined(separator: ", ")
    }

    private static func transformDescription(
        _ capabilities: FileCapabilities
    ) -> String {
        let entries = capabilities.formats.compactMap { capability -> String? in
            guard let transform = capability.createContract?.transform else {
                return nil
            }
            return "\(capability.format.rawValue)=\(transform.rawValue)"
        }
        return "Required create transforms: " + entries.joined(separator: ", ")
    }

    private static func patchDescription(
        _ capabilities: FileCapabilities
    ) -> String {
        let formats = capabilities.formats.compactMap { capability in
            capability.updateModes.contains(.patch)
                ? capability.format.rawValue
                : nil
        }
        return "Up to \(FileMutationRequestLimits.maximumReplacements) exact, unique replacements for patch-capable formats: "
            + formats.joined(separator: ", ")
    }

    /// Describes create input directly from the backend catalog projection.
    private static func createContractDescription(
        _ capabilities: FileCapabilities
    ) -> String {
        let entries = capabilities.formats.compactMap { capability -> String? in
            guard let contract = capability.createContract else { return nil }
            let transform = contract.transform.map { "+\($0.rawValue)" } ?? ""
            return "\(capability.format.rawValue)=\(contract.input.rawValue)\(transform)"
        }
        return "Concrete stored file format and required input: "
            + entries.joined(separator: ", ")
    }

    /// Describes supported update modes directly from catalog registrations.
    private static func updateModeDescription(
        _ capabilities: FileCapabilities
    ) -> String {
        let entries = capabilities.formats.compactMap { capability -> String? in
            guard !capability.updateModes.isEmpty else { return nil }
            let modes = capability.updateModes
                .map(\.rawValue)
                .sorted()
                .joined(separator: "|")
            return "\(capability.format.rawValue)=\(modes)"
        }
        return "Format-specific update modes: " + entries.joined(separator: ", ")
    }

    private static var updateModeVariants: [Value] {
        [
            .object([
                "properties": .object([
                    "mode": .object(["enum": .array([.string("replace"), .string("append")])]),
                    "replacements": .bool(false),
                ]),
                "required": .array([.string("content")]),
            ]),
            .object([
                "properties": .object([
                    "mode": .object(["const": .string("patch")]),
                    "content": .bool(false),
                ]),
                "required": .array([.string("replacements")]),
            ]),
        ]
    }

    /// Builds the common format/path contract plus operation-specific fields.
    private static func inputSchema(
        formats: [FileFormat],
        formatDescription: String,
        pathDescription: String,
        additionalProperties: [FileToolArgument: Value] = [:],
        additionalRequired: [FileToolArgument] = [],
        alternatives: [Value] = []
    ) -> Value {
        var properties = additionalProperties
        properties[.format] = .object([
            "type": .string("string"),
            "enum": .array(formats.map { .string($0.rawValue) }),
            "description": .string(formatDescription)
        ])
        properties[.path] = .object([
            "type": .string("string"),
            "description": .string(pathDescription)
        ])
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": argumentObject(properties),
            "required": requiredArguments([.format, .path] + additionalRequired),
            "additionalProperties": .bool(false),
        ]
        if !alternatives.isEmpty { schema["oneOf"] = .array(alternatives) }
        return .object(schema)
    }

    /// Schema for exact-byte compare-and-swap revision preconditions.
    private static var expectedRevisionSchema: Value {
        .object([
            "type": .string("string"),
            "pattern": .string("^sha256:[0-9a-f]{64}$"),
            "description": .string(
                "Opaque revision returned by read_file. Required for updates, deletes, and any text continuation whose byte_offset is greater than zero. Never guess it."
            ),
        ])
    }

    private static var metadataOutputSchema: Value {
        .object([
            "type": .string("object"),
            "description": .string("Content-free metadata; incomplete_fields names any omitted or display-shortened fields, not an exact omitted-item count"),
            "properties": .object([
                "incomplete_fields": .object([
                    "type": .string("array"),
                    "maxItems": .int(FileMetadataField.allCases.count),
                    "uniqueItems": .bool(true),
                    "items": .object([
                        "type": .string("string"),
                        "enum": .array(FileMetadataField.allCases.map { .string($0.rawValue) }),
                    ]),
                    "description": .string("Fields with omitted identifiers/entries or shortened display text; empty when no summary field is incomplete"),
                ]),
                "format": .object([
                    "type": .string("string"),
                    "enum": .array([.string("markdown"), .string("pdf")]),
                    "description": .string("Metadata representation: markdown or pdf"),
                ]),
                "byte_count": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                    "description": .string("Exact current file size in bytes"),
                ]),
                "modified_at": .object([
                    "type": .string("string"),
                    "description": .string("Filesystem modification time"),
                ]),
                "title": .object([
                    "type": .string("string"),
                    "maxLength": .int(FileMetadataLimits.maximumStringBytes),
                    "description": .string("Markdown or PDF title, at most 1024 UTF-8 bytes; shortening is disclosed in incomplete_fields"),
                ]),
                "tags": .object([
                    "type": .string("array"),
                    "maxItems": .int(FileMetadataLimits.maximumTags),
                    "items": .object([
                        "type": .string("string"),
                        "maxLength": .int(FileMetadataLimits.maximumStringBytes),
                    ]),
                    "description": .string("Exact normalized Markdown tags; oversized identifiers are omitted, never shortened, and omissions are disclosed"),
                ]),
                "word_count": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                    "description": .string("Markdown body word count"),
                ]),
                "outgoing_link_targets": .object([
                    "type": .string("array"),
                    "maxItems": .int(FileMetadataLimits.maximumOutgoingLinks),
                    "items": .object([
                        "type": .string("string"),
                        "maxLength": .int(FileMetadataLimits.maximumStringBytes),
                    ]),
                    "description": .string("Distinct exact local wiki/inline Markdown targets in source order, at most 64 KiB total; incomplete_fields reports any omission or scan limit"),
                ]),
                "author": .object([
                    "type": .string("string"),
                    "maxLength": .int(FileMetadataLimits.maximumStringBytes),
                    "description": .string("PDF author, at most 1024 UTF-8 bytes; shortening is disclosed in incomplete_fields"),
                ]),
                "page_count": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                    "description": .string("Total physical PDF page count"),
                ]),
                "page_labels": .object([
                    "type": .string("array"),
                    "maxItems": .int(FileMetadataLimits.maximumPDFPageLabels),
                    "items": .object([
                        "type": .string("string"),
                        "maxLength": .int(FileMetadataLimits.maximumStringBytes),
                    ]),
                    "description": .string("PDF display labels in physical order, each at most 1024 UTF-8 bytes; shortening or omission is disclosed"),
                ]),
                "page_labels_truncated": .object([
                    "type": .string("boolean"),
                    "description": .string("True when additional PDF page labels were omitted"),
                ]),
                "outline": .object([
                    "type": .string("array"),
                    "maxItems": .int(FileMetadataLimits.maximumPDFOutlineEntries),
                    "description": .string("Bounded flattened PDF outline entries"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "label": .object([
                                "type": .string("string"),
                                "maxLength": .int(FileMetadataLimits.maximumStringBytes),
                                "description": .string("Display label, at most 1024 UTF-8 bytes; shortening marks outline in incomplete_fields"),
                            ]),
                            "page": .object([
                                "type": .string("integer"),
                                "minimum": .int(1),
                                "description": .string("One-based physical PDF page when the destination resolves"),
                            ]),
                            "depth": .object([
                                "type": .string("integer"),
                                "minimum": .int(0),
                                "description": .string("Zero-based outline nesting depth"),
                            ]),
                        ]),
                        "required": .array([.string("label"), .string("depth")]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
                "outline_truncated": .object([
                    "type": .string("boolean"),
                    "description": .string("True when additional PDF outline entries were omitted"),
                ]),
            ]),
            "required": .array([.string("format"), .string("byte_count"), .string("incomplete_fields")]),
            "additionalProperties": .bool(false),
        ])
    }

    /// Builds the structured metadata schema returned alongside content blocks.
    private static func outputSchema(
        required: [FileToolOutputField],
        includesRevision: Bool = false,
        includesReadFields: Bool = false
    ) -> Value {
        var properties: [String: Value] = [
                FileToolOutputField.path.rawValue: .object([
                    "type": .string("string"),
                    "description": .string("Vault-relative result path"),
                ]),
                FileToolOutputField.area.rawValue: .object([
                    "type": .string("string"),
                    "enum": .array(VaultArea.allCases.map { .string($0.rawValue) }),
                    "description": .string("Structural vault area containing the result"),
                ]),
                FileToolOutputField.revision.rawValue: .object([
                    "type": .string("string"),
                    "pattern": .string("^sha256:[0-9a-f]{64}$"),
                    "description": .string("Exact-byte revision for the current notes content; use it for the next mutation or text continuation"),
                ]),
                FileToolOutputField.readMetadata.rawValue: metadataOutputSchema,
                FileToolOutputField.canvasNodeID.rawValue: .object([
                    "type": .string("string"),
                    "description": .string("Exact Canvas node selected for this decoded field read"),
                ]),
                FileToolOutputField.canvasField.rawValue: .object([
                    "type": .string("string"),
                    "enum": .array(CanvasReadField.allCases.map { .string($0.rawValue) }),
                    "description": .string("Exact Canvas field selected for this decoded field read"),
                ]),
                FileToolOutputField.textWindow.rawValue: .object([
                    "type": .string("object"),
                    "description": .string("UTF-8 byte window returned for a bounded text content read"),
                    "properties": .object([
                        FileToolOutputField.byteOffset.rawValue: .object([
                            "type": .string("integer"),
                            "minimum": .int(0),
                            "description": .string("Zero-based UTF-8 byte offset of this chunk"),
                        ]),
                        FileToolOutputField.byteCount.rawValue: .object([
                            "type": .string("integer"),
                            "minimum": .int(0),
                            "maximum": .int(FileReadRequestLimits.maximumTextChunkBytes),
                            "description": .string("UTF-8 bytes returned in this chunk"),
                        ]),
                        FileToolOutputField.totalBytes.rawValue: .object([
                            "type": .string("integer"),
                            "minimum": .int(0),
                            "description": .string("Exact total UTF-8 byte count of the current raw file or selected Canvas field"),
                        ]),
                        FileToolOutputField.nextByteOffset.rawValue: .object([
                            "type": .string("integer"),
                            "minimum": .int(0),
                            "description": .string("Offset for the next chunk; continue with the same revision as expected_revision"),
                        ]),
                    ]),
                    "required": .array([
                        .string(FileToolOutputField.byteOffset.rawValue),
                        .string(FileToolOutputField.byteCount.rawValue),
                        .string(FileToolOutputField.totalBytes.rawValue),
                    ]),
                    "additionalProperties": .bool(false),
                ]),
        ]
        if !required.contains(.revision) && !includesRevision {
            properties.removeValue(forKey: FileToolOutputField.revision.rawValue)
        }
        if !includesReadFields {
            properties.removeValue(forKey: FileToolOutputField.readMetadata.rawValue)
            properties.removeValue(forKey: FileToolOutputField.canvasNodeID.rawValue)
            properties.removeValue(forKey: FileToolOutputField.canvasField.rawValue)
            properties.removeValue(forKey: FileToolOutputField.textWindow.rawValue)
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0.rawValue) }),
            "additionalProperties": .bool(false),
        ])
    }

    /// Converts typed argument properties to their MCP wire names.
    private static func argumentObject(
        _ properties: [FileToolArgument: Value]
    ) -> Value {
        .object(Dictionary(uniqueKeysWithValues: properties.map {
            ($0.key.rawValue, $0.value)
        }))
    }

    /// Builds a JSON Schema required list from typed argument names.
    private static func requiredArguments(
        _ arguments: [FileToolArgument]
    ) -> Value {
        .array(arguments.map { .string($0.rawValue) })
    }
}
